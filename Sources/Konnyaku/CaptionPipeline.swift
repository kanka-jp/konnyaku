import Foundation
import Speech
import Synchronization
import Translation

// 認識エンジンへ供給済みの audio 累積秒。capture callback (非 MainActor) が進め、
// MainActor の判定側が読むため Mutex で共有する
private final class AudioFeedClock: Sendable {
    private let seconds = Mutex(0.0)

    func advance(bySeconds delta: Double) {
        seconds.withLock { $0 += delta }
    }

    func now() -> Double {
        seconds.withLock { $0 }
    }

    func reset() {
        seconds.withLock { $0 = 0 }
    }
}

@MainActor
final class CaptionPipeline {
    let state: CaptionState

    private let transcription = TranscriptionEngine()
    private let audio = AudioCaptureEngine()
    private let onFailure: @MainActor () -> Void
    private var recognitionTask: Task<Void, Never>?
    private var correctionTask: Task<Void, Never>?
    private var translationTask: Task<Void, Never>?
    private var volatileTranslationTask: Task<Void, Never>?
    // updateVolatileTranslationEnabled の resolvePair 待ち。完了前に OFF へ戻された場合に
    // cancel して、古い ON 要求が後から worker を起動してしまうのを防ぐ
    private var volatileTranslationStartTask: Task<Void, Never>?
    private var pruneTask: Task<Void, Never>?
    private var pendingCorrection: AsyncStream<(text: String, generation: Int)>.Continuation?
    private var pendingSourceText: AsyncStream<(text: String, generation: Int)>.Continuation?
    private var pendingVolatileText: AsyncStream<(text: String, generation: Int)>.Continuation?
    // OFF→ON 高速切替時の再起動要求。即座に新規起動すると correctionBacklog 等の
    // 共有状態が二重起動で壊れるため、旧 correctionTask の自然終了を待って適用する
    private var pendingCorrectionRestart: (inputLocale: Locale, vocabulary: [String])?
    // 旧 worker の drain 完了 (restart 予約の有無に関わらず) まで、追い越し防止のため直接流さず保留する確定文
    private var pendingFinalTextsAwaitingCorrectionDrain: [(text: String, generation: Int)] = []
    private var correctionBacklog = 0
    private var segmentThreshold = CaptionPipeline.latinSegmentThreshold
    // clauseAware の節境界規則は日本語表層形 (接続助詞・て形等) 依存のため日本語入力のみ適用。
    // 他言語では tail 句読点 window ベースの current を継続 (他言語未評価のため conservative)
    private var segmentationPolicy: SegmentationPolicy = .current
    private var forcedFinalizeInFlight = false
    // pauseAware のポーズ判定入力 (audio 供給時刻と最新結果の audio 終端)。
    // .current 運用では参照されないが観測値として常に更新する。判定は認識結果の
    // 到着時のみ走るため、pauseAware を本番で有効化するには供給側の判定トリガー
    // (eval replay の onChunkFed 相当。無音中は volatile が来ず判定機会が無い) の
    // 配線が別途必要
    private let audioFeedClock = AudioFeedClock()
    private var lastResultAudioEnd: TimeInterval?

    init(state: CaptionState, onFailure: @escaping @MainActor () -> Void) {
        self.state = state
        self.onFailure = onFailure
    }

    // 1 字幕行に収まる程度の文字数。CJK は 1 文字の情報量が大きいため短めに切る
    // (private でないのは eval が同じ閾値で replay するため。nonisolated は
    // MainActor 外の eval helper からの参照用)
    nonisolated static let cjkSegmentThreshold = 40
    nonisolated static let latinSegmentThreshold = 90
    private static let maxTranslationQueueDepth = 2

    func start(
        inputLocale: Locale,
        outputLanguage: Locale.Language,
        translationEnabled: Bool,
        useLowLatencyTranslation: Bool,
        volatileTranslationEnabled: Bool,
        correctionEnabled: Bool,
        contextualTerms: [String],
        resolvedSource: Locale.Language,
        resolvedTarget: Locale.Language,
        onSpeechModelDownload: (@MainActor (Progress?) -> Void)? = nil
    ) async throws {
        let transcriber = try await transcription.prepare(
            locale: inputLocale, onDownloadProgress: onSpeechModelDownload)
        guard let analyzerFormat = transcription.analyzerFormat else {
            throw KonnyakuError.audioFormatUnavailable
        }

        let languageCode = inputLocale.language.languageCode
        segmentThreshold = (languageCode == .japanese || languageCode == .chinese || languageCode == .korean)
            ? Self.cjkSegmentThreshold
            : Self.latinSegmentThreshold
        segmentationPolicy = languageCode == .japanese ? .clauseAware : .current
        forcedFinalizeInFlight = false

        audioFeedClock.reset()
        lastResultAudioEnd = nil
        let inputContinuation = try await transcription.start(contextualTerms: contextualTerms)
        let feedClock = audioFeedClock
        let sampleRate = analyzerFormat.sampleRate
        try audio.start(convertingTo: analyzerFormat) { input in
            if sampleRate > 0 {
                feedClock.advance(bySeconds: Double(input.buffer.frameLength) / sampleRate)
            }
            inputContinuation.yield(input)
        }

        if translationEnabled {
            startTranslationWorker(
                resolvedSource: resolvedSource,
                resolvedTarget: resolvedTarget,
                lowLatency: useLowLatencyTranslation
            )
            // worker を起動しなければ pendingVolatileText が nil のまま yield が no-op になる
            if volatileTranslationEnabled {
                startVolatileTranslationWorker(
                    resolvedSource: resolvedSource,
                    resolvedTarget: resolvedTarget,
                    lowLatency: useLowLatencyTranslation
                )
            }
        }
        // 補正プロンプトの few-shot・フィラー語彙・語尾復元は日本語専用のため、
        // 他言語入力では worker を起動せず誤った書き換えを避ける
        if correctionEnabled && CorrectionEngine.isAvailable
            && inputLocale.language.languageCode == .japanese {
            startCorrectionWorker(inputLocale: inputLocale, vocabulary: contextualTerms)
        }

        recognitionTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    // 句読点のみ等でフィルタされる final でも確定は届いているため、
                    // guard より先に解除しないと以降の強制区切りが永久停止する
                    if result.isFinal {
                        self.forcedFinalizeInFlight = false
                    }
                    // 時間属性が無い結果でも認識活動はあった (= その供給時刻まで
                    // 無音でない) ため、供給時刻へ fallback して stale な前セグメント
                    // 終端が見かけのポーズを作るのを防ぐ
                    self.lastResultAudioEnd =
                        Self.audioEndSeconds(of: result.text) ?? self.audioFeedClock.now()
                    let text = String(result.text.characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    // 句読点のみの結果は表示・翻訳とも無意味なので落とす
                    guard text.contains(where: { $0.isLetter || $0.isNumber }) else {
                        // final を捨ててもセグメントは切り替わっている。世代を進めないと
                        // 前の文の in-flight 追従訳が次の文の追従訳として受理される
                        if result.isFinal {
                            self.state.discardVolatileSegment()
                        }
                        continue
                    }
                    if result.isFinal {
                        debugLog("final arrived (len=\(text.count))\(logContentSuffix(text))")
                        // 確定訳にこの文の volatile 世代 (appendFinalSource が進める前) を
                        // 紐付け、追従訳の置き換え対象を自分の文に限定する
                        let generation = self.state.volatileGeneration
                        self.state.appendFinalSource(text)
                        // 補正 worker がいる場合は補正後テキストが表示差し替えと翻訳を担う
                        switch Self.resolveFinalTextRoute(
                            hasPendingCorrection: self.pendingCorrection != nil,
                            hasDrainingCorrectionTask: self.correctionTask != nil
                        ) {
                        case .correction:
                            self.correctionBacklog += 1
                            self.pendingCorrection?.yield((text, generation))
                        case .bufferUntilDrainCompletes:
                            // 旧 worker の drain 完了まで、無補正のまま流すと補正後テキストを
                            // 追い越しうるため保留する (restart 予約の有無に関わらず)
                            self.pendingFinalTextsAwaitingCorrectionDrain.append((text, generation))
                        case .direct:
                            self.pendingSourceText?.yield((text, generation))
                        }
                    } else {
                        self.logVolatileProgress(text)
                        self.state.setVolatileSource(text)
                        self.yieldVolatileForTranslation(text)
                        self.forceFinalizeIfOverflowing(volatile: text)
                    }
                }
            } catch {
                // 停止操作由来の CancellationError を偽エラーとして表示しない
                guard !(error is CancellationError), let self else { return }
                debugLog("recognition error: \(error)")
                self.state.statusMessage = "\(t("status.recognition_error")): \(error.localizedDescription)"
                // 認識ストリームが死んだまま isRunning が残る zombie 状態を防ぐ
                self.onFailure()
            }
        }

        startPruneWorker()
        state.isRunning = true
    }

    enum CorrectionToggleAction: Equatable {
        case startNow
        case deferRestart
        case stopAndClearPending
        case noop
    }

    // OFF 要求は pendingCorrection の有無に関わらず常に .stopAndClearPending を返す
    // (有無だけで判定すると OFF→ON→OFF 高速切替で保留中の再起動要求を取りこぼすため。純関数・テスト対象)
    nonisolated static func resolveCorrectionToggleAction(
        shouldRun: Bool, hasPendingCorrection: Bool, hasActiveCorrectionTask: Bool
    ) -> CorrectionToggleAction {
        guard shouldRun else { return .stopAndClearPending }
        guard !hasPendingCorrection else { return .noop }
        return hasActiveCorrectionTask ? .deferRestart : .startNow
    }

    enum FinalTextRoute: Equatable {
        case correction
        case bufferUntilDrainCompletes
        case direct
    }

    nonisolated static func resolveFinalTextRoute(
        hasPendingCorrection: Bool, hasDrainingCorrectionTask: Bool
    ) -> FinalTextRoute {
        guard !hasPendingCorrection else { return .correction }
        return hasDrainingCorrectionTask ? .bufferUntilDrainCompletes : .direct
    }

    // bufferingNewest は consumer の drain 状況次第で生き残る要素が非決定的になるため、
    // 直近 N 件へ明示的に切り詰めてから yield する
    private func flushDirectlyToTranslation(_ items: [(text: String, generation: Int)]) {
        for item in items.suffix(Self.maxTranslationQueueDepth) {
            pendingSourceText?.yield(item)
        }
    }

    // 稼働中に補正 ON/OFF を切り替える。パイプライン全体を再起動せず補正 worker だけ
    // 起動・停止する (全体再起動は字幕が一瞬途切れ prepareTranslation も再実行されるため)
    func updateCorrectionEnabled(_ enabled: Bool, inputLocale: Locale, vocabulary: [String]) {
        let shouldRun = enabled && CorrectionEngine.isAvailable
            && inputLocale.language.languageCode == .japanese
        switch Self.resolveCorrectionToggleAction(
            shouldRun: shouldRun,
            hasPendingCorrection: pendingCorrection != nil,
            hasActiveCorrectionTask: correctionTask != nil
        ) {
        case .startNow:
            startCorrectionWorker(inputLocale: inputLocale, vocabulary: vocabulary)
        case .deferRestart:
            pendingCorrectionRestart = (inputLocale, vocabulary)
        case .stopAndClearPending:
            // backlog を drain してから自然終了させる。hard cancel すると滞留中の文が
            // pendingSourceText に転送されず訳されないまま取り残される
            pendingCorrectionRestart = nil
            pendingCorrection?.finish()
            pendingCorrection = nil
            // drain 中は完了コールバックが flush するため、drain 中でない場合のみここで flush する
            if correctionTask == nil {
                flushDirectlyToTranslation(pendingFinalTextsAwaitingCorrectionDrain)
                pendingFinalTextsAwaitingCorrectionDrain.removeAll()
            }
        case .noop:
            break
        }
    }

    // 確定訳 worker が停止済み (notInstalled 等) なら false を返し、呼び出し元のフル再起動フォールバックを許容する
    @discardableResult
    func updateVolatileTranslationEnabled(
        _ enabled: Bool,
        inputLanguage: Locale.Language,
        outputLanguage: Locale.Language,
        lowLatency: Bool
    ) -> Bool {
        guard translationTask != nil else { return false }
        let isActive = volatileTranslationTask != nil || volatileTranslationStartTask != nil
        guard enabled != isActive else { return true }
        if enabled {
            // detached: 呼び出し元 Task のキャンセルを継承すると、resolvePair 待ち中に
            // 呼び出し元が終了しただけで ON 要求が握り潰され isActive が true のまま残る
            volatileTranslationStartTask = Task.detached { [weak self] in
                guard let self else { return }
                let pair = await TranslationSupport.resolvePair(
                    input: inputLanguage, output: outputLanguage)
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    self.volatileTranslationStartTask = nil
                    self.startVolatileTranslationWorker(
                        resolvedSource: pair.source, resolvedTarget: pair.target, lowLatency: lowLatency)
                }
            }
        } else {
            volatileTranslationStartTask?.cancel()
            volatileTranslationStartTask = nil
            pendingVolatileText?.finish()
            pendingVolatileText = nil
            volatileTranslationTask?.cancel()
            volatileTranslationTask = nil
            // worker 停止だけでは表示中の追従訳が残り続けるため明示的にクリアする
            state.setVolatileTranslation("", generation: state.volatileGeneration)
        }
        return true
    }

    // volatile の伸びを診断ログに残す (毎更新は noise のため 10 字刻みの閾値跨ぎのみ)
    private var lastLoggedVolatileBucket = -1
    private func logVolatileProgress(_ text: String) {
        let bucket = text.count / 10
        guard bucket != lastLoggedVolatileBucket else { return }
        lastLoggedVolatileBucket = bucket
        debugLog("volatile len=\(text.count)\(logContentSuffix(text))")
    }

    // ごく短い話し始めの訳は chatter になるだけなので追従翻訳に流さない
    // (private でないのは eval が同じ閾値で追従訳の erasure を再現するため)
    nonisolated static let minVolatileTranslationLength = 3

    private func yieldVolatileForTranslation(_ text: String) {
        guard text.count >= Self.minVolatileTranslationLength else { return }
        // 世代は yield 時点で確定させる。worker の dequeue 時に読むと、buffer 滞留中に
        // 文が確定した古いテキストへ新しい世代が付き、stale 判定をすり抜ける
        pendingVolatileText?.yield((text, state.volatileGeneration))
    }

    // 話し中 (volatile) テキストの追従訳。文確定を待たず下段を随時更新し、自分の文の
    // 確定訳が来たら置き換わる (CaptionState.appendTranslation が自分の世代以前の追従訳を消す)。
    // 確定翻訳と別 worker・別 session なのは、確定訳の品質と順序を追従訳の
    // 割り込みで乱さないため
    private func startVolatileTranslationWorker(
        resolvedSource: Locale.Language,
        resolvedTarget: Locale.Language,
        lowLatency: Bool
    ) {
        // 翻訳が追いつかない間に届いた volatile は最新 1 件だけ残して捨てる
        // (翻訳所要時間そのものが自然な throttle になる)
        let (stream, continuation) = AsyncStream.makeStream(
            of: (text: String, generation: Int).self,
            bufferingPolicy: .bufferingNewest(1)
        )
        pendingVolatileText = continuation

        let state = self.state
        volatileTranslationTask = Task.detached {
            let session = TranslationSupport.makeSession(
                source: resolvedSource, target: resolvedTarget, lowLatency: lowLatency)
            do {
                try await session.prepareTranslation()
            } catch {
                debugLog("volatile prepareTranslation error: \(error)")
            }
            for await (text, generation) in stream {
                if Task.isCancelled { return }
                // buffer 滞留中に文が確定した項目は翻訳せず捨てる
                guard generation == (await state.volatileGeneration) else { continue }
                do {
                    let translated = try await session.translate(text).targetText
                    await MainActor.run {
                        guard !Task.isCancelled else { return }
                        state.setVolatileTranslation(translated, generation: generation)
                    }
                } catch {
                    guard !(error is CancellationError), !Task.isCancelled else { return }
                    // 追従訳は best-effort。失敗しても確定訳が後から表示される
                    debugLog("volatile translate error: \(error)")
                }
            }
        }
    }

    // 認識結果の attributed runs から audio 区間の終端秒を取り出す (pauseAware の
    // ポーズ判定入力。時間属性が無い run のみの結果では nil)
    nonisolated static func audioEndSeconds(of text: AttributedString) -> TimeInterval? {
        var end: TimeInterval?
        for run in text.runs {
            guard let range = run.audioTimeRange else { continue }
            end = max(end ?? range.end.seconds, range.end.seconds)
        }
        return end
    }

    // 切れ目なく話し続けると isFinal が届かず翻訳が始まらないため強制確定で文を区切る。
    // 確定結果が届くまで再要求しない (volatile 更新ごとの重複要求を防ぐ)
    private func forceFinalizeIfOverflowing(volatile text: String) {
        let context = SegmentationPolicy.Context(
            lastResultAudioEnd: lastResultAudioEnd,
            audioFedThrough: audioFeedClock.now())
        guard !forcedFinalizeInFlight,
            segmentationPolicy.shouldForceFinalize(
                text: text, threshold: segmentThreshold, context: context)
        else { return }
        forcedFinalizeInFlight = true
        debugLog("force finalize requested (len=\(text.count))")
        Task { [weak self] in
            guard let self else { return }
            // 失敗すると確定結果が届かず flag が解除されないため、失敗時はここで解除する
            let finalized = await self.transcription.finalizeCurrentSegment()
            if !finalized {
                self.forcedFinalizeInFlight = false
            }
        }
    }

    // 新しい行が来なくても古い字幕行が時間で消えるように定期的に失効を確認する
    private func startPruneWorker() {
        pruneTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.state.pruneExpired()
            }
        }
    }

    // 順序保証のため補正は 1 本の worker で逐次処理する。補正が追いつかない場合は
    // 滞留分の補正を skip して素通しし、順序を保ったまま欠落なしで遅延を回収する
    // (キュー側で drop すると翻訳の欠落か順序逆転のどちらかが起きる)。
    // 閾値は現在処理中の文を除いた残キュー数に対して適用する (decrement 後に判定)
    private static let maxCorrectionBacklog = 3

    private func startCorrectionWorker(inputLocale: Locale, vocabulary: [String]) {
        correctionBacklog = 0
        let languageName = Locale(identifier: "en-US")
            .localizedString(forIdentifier: inputLocale.identifier) ?? inputLocale.identifier
        let corrector = CorrectionEngine(languageName: languageName, vocabulary: vocabulary)
        let (stream, continuation) = AsyncStream.makeStream(of: (text: String, generation: Int).self)
        pendingCorrection = continuation

        correctionTask = Task { [weak self] in
            for await (raw, generation) in stream {
                guard let self, !Task.isCancelled else { return }
                self.correctionBacklog -= 1
                let corrected: String
                if self.correctionBacklog >= Self.maxCorrectionBacklog {
                    corrected = raw
                } else {
                    let correctionStart = ContinuousClock.now
                    corrected = await corrector.correct(raw)
                    debugLog("correction done in \(ContinuousClock.now - correctionStart)\(logContentSuffix(corrected))")
                }
                guard !Task.isCancelled else { return }
                // 同文でも呼ぶ: addedAt を refresh し、補正確認済みの行が
                // 対応する翻訳の表示前に失効する非対称を防ぐ
                self.state.replaceFinalSource(raw, with: corrected, generation: generation)
                self.pendingSourceText?.yield((corrected, generation))
            }
            // stream の自然終了 (finish 経由の drain 完了) 時のみ到達する。キャンセル時は
            // ループ内の early return でここに来ないため stop() の後始末とは競合しない
            guard let self else { return }
            self.correctionTask = nil
            let buffered = self.pendingFinalTextsAwaitingCorrectionDrain
            self.pendingFinalTextsAwaitingCorrectionDrain.removeAll()
            if let pending = self.pendingCorrectionRestart {
                self.pendingCorrectionRestart = nil
                self.startCorrectionWorker(inputLocale: pending.inputLocale, vocabulary: pending.vocabulary)
                // drain 待ち中に保留された確定文を、到着順のまま新 worker に流す
                for item in buffered {
                    self.correctionBacklog += 1
                    self.pendingCorrection?.yield(item)
                }
            } else {
                // restart 予約なし (OFF 確定) の場合、保留文を旧 worker の補正結果より
                // 先に流さないよう到着順のまま無補正で flush する
                self.flushDirectlyToTranslation(buffered)
            }
        }
    }

    private func startTranslationWorker(
        resolvedSource: Locale.Language,
        resolvedTarget: Locale.Language,
        lowLatency: Bool
    ) {
        // ライブ字幕では滞留した古い文を訳す価値がないため、翻訳が追いつかない場合は
        // 新しい文を優先して古い待ち行列を捨てる (実測データが無いため保守的に絞り、
        // 最大遅延を短く抑える)
        let (sourceStream, sourceContinuation) = AsyncStream.makeStream(
            of: (text: String, generation: Int).self,
            bufferingPolicy: .bufferingNewest(Self.maxTranslationQueueDepth)
        )
        pendingSourceText = sourceContinuation

        // TranslationSession は non-Sendable のため、detached task 内でローカル所有して
        // actor 境界を越える sending を発生させない
        let state = self.state
        translationTask = Task.detached { [weak self] in
            debugLog("translation strategy: \(lowLatency ? "lowLatency" : "highFidelity")")
            let session = TranslationSupport.makeSession(
                source: resolvedSource, target: resolvedTarget, lowLatency: lowLatency)
            do {
                // モデルを事前ロードして初回翻訳の待ちを短縮する
                let prepareStart = ContinuousClock.now
                try await session.prepareTranslation()
                debugLog("prepareTranslation ok in \(ContinuousClock.now - prepareStart)")
            } catch {
                debugLog("prepareTranslation error: \(error)")
                // モデル未インストールは回復不可能なため、確定するたび失敗し続ける
                // translate loop に入らず諦める
                if TranslationError.notInstalled ~= error {
                    await MainActor.run {
                        // cancel 後に新しい translationTask が起動済みの場合、状態上書きを防ぐ
                        guard !Task.isCancelled else { return }
                        state.setStatusMessage(t("status.translation_model_not_installed"))
                        // translationTask を残すと updateVolatileTranslationEnabled が
                        // 「確定訳 worker 稼働中」と誤認し追従訳 worker を起動してしまう
                        self?.translationTask = nil
                        self?.pendingSourceText?.finish()
                        self?.pendingSourceText = nil
                        // 追従訳 worker も明示的に止める。残すと上記ガードが effectively 死に、
                        // OFF 操作で追従訳を止められなくなる
                        self?.volatileTranslationStartTask?.cancel()
                        self?.volatileTranslationStartTask = nil
                        self?.pendingVolatileText?.finish()
                        self?.pendingVolatileText = nil
                        self?.volatileTranslationTask?.cancel()
                        self?.volatileTranslationTask = nil
                        state.setVolatileTranslation("", generation: state.volatileGeneration)
                    }
                    return
                }
            }
            // 確定訳を失うのは体験上のコストが大きいため 1 回だけ再試行する
            // (無制限リトライはレイテンシ悪化を招くため 1 回に限定)
            func translateWithRetry(_ text: String) async throws -> TranslationSession.Response {
                do {
                    return try await session.translate(text)
                } catch {
                    guard !(error is CancellationError), !Task.isCancelled else { throw error }
                    debugLog("translate retry after error: \(error)")
                    try await Task.sleep(for: .milliseconds(300))
                    return try await session.translate(text)
                }
            }
            for await (sourceText, generation) in sourceStream {
                // キャンセル後に in-flight の翻訳結果で次セッションの state を汚さない
                if Task.isCancelled { return }
                do {
                    debugLog("translate start (len=\(sourceText.count))\(logContentSuffix(sourceText))")
                    let translateStart = ContinuousClock.now
                    let translated = try await translateWithRetry(sourceText).targetText
                    debugLog("translate done in \(ContinuousClock.now - translateStart)\(logContentSuffix(translated))")
                    // cancel は stop() (MainActor) から届くため、同一 executor 上で
                    // 判定と反映を同期実行し、hop 中の cancel による stale append を塞ぐ
                    await MainActor.run {
                        guard !Task.isCancelled else { return }
                        state.appendTranslation(translated, generation: generation)
                    }
                } catch {
                    guard !(error is CancellationError), !Task.isCancelled else { return }
                    debugLog("translate error: \(error)")
                    let message = "\(t("status.translation_error")): \(error.localizedDescription)"
                    await MainActor.run {
                        guard !Task.isCancelled else { return }
                        state.setStatusMessage(message)
                    }
                }
            }
        }
    }

    func stop() async {
        audio.stop()
        await transcription.stop()
        pendingCorrection?.finish()
        pendingCorrection = nil
        pendingSourceText?.finish()
        pendingSourceText = nil
        pendingVolatileText?.finish()
        pendingVolatileText = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        correctionTask?.cancel()
        correctionTask = nil
        pendingCorrectionRestart = nil
        pendingFinalTextsAwaitingCorrectionDrain.removeAll()
        translationTask?.cancel()
        translationTask = nil
        volatileTranslationTask?.cancel()
        volatileTranslationTask = nil
        volatileTranslationStartTask?.cancel()
        volatileTranslationStartTask = nil
        pruneTask?.cancel()
        pruneTask = nil
        state.isRunning = false
        // pruneTask も止まるため、残した表示は失効せず残り続ける (確定行も含めて消す)
        state.clearVolatile()
        state.clearFinalLines()
    }
}
