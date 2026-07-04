import Foundation
import Speech
import Translation

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
    private var correctionBacklog = 0
    private var segmentThreshold = CaptionPipeline.latinSegmentThreshold
    private var forcedFinalizeInFlight = false

    init(state: CaptionState, onFailure: @escaping @MainActor () -> Void) {
        self.state = state
        self.onFailure = onFailure
    }

    // 1 字幕行に収まる程度の文字数。CJK は 1 文字の情報量が大きいため短めに切る
    private static let cjkSegmentThreshold = 40
    private static let latinSegmentThreshold = 90
    // 閾値超過後も句読点が見つからない場合に強制確定を保留する上限 (閾値の倍数)
    nonisolated private static let forceFinalizeGraceMultiplier = 1.5
    // 句読点の有無を確認する対象は末尾付近のみ (先頭寄りの句読点で誤って早期確定しないため)
    nonisolated private static let forceFinalizePunctuationTailWindow = 10
    nonisolated private static let sentenceBreakPunctuation: Set<Character> = [
        "、", "。", "，", "．", "！", "？", ",", ".", "!", "?",
    ]

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
        forcedFinalizeInFlight = false

        let inputContinuation = try await transcription.start(contextualTerms: contextualTerms)
        try audio.start(convertingTo: analyzerFormat) { input in
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
                        if let pendingCorrection = self.pendingCorrection {
                            self.correctionBacklog += 1
                            pendingCorrection.yield((text, generation))
                        } else {
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

    // 稼働中に補正 ON/OFF を切り替える。パイプライン全体を再起動せず補正 worker だけ
    // 起動・停止する (全体再起動は字幕が一瞬途切れ prepareTranslation も再実行されるため)
    func updateCorrectionEnabled(_ enabled: Bool, inputLocale: Locale, vocabulary: [String]) {
        let shouldRun = enabled && CorrectionEngine.isAvailable
            && inputLocale.language.languageCode == .japanese
        guard shouldRun != (pendingCorrection != nil) else { return }
        if shouldRun {
            guard correctionTask == nil else {
                pendingCorrectionRestart = (inputLocale, vocabulary)
                return
            }
            startCorrectionWorker(inputLocale: inputLocale, vocabulary: vocabulary)
        } else {
            // backlog を drain してから自然終了させる。hard cancel すると滞留中の文が
            // pendingSourceText に転送されず訳されないまま取り残される
            pendingCorrectionRestart = nil
            pendingCorrection?.finish()
            pendingCorrection = nil
        }
    }

    // 稼働中にリアルタイム翻訳 ON/OFF を切り替える。パイプライン全体を再起動せず追従訳 worker だけ
    // 起動・停止する。確定訳 worker が動いていなければ (= 翻訳自体が無効) 無視する
    func updateVolatileTranslationEnabled(
        _ enabled: Bool,
        inputLanguage: Locale.Language,
        outputLanguage: Locale.Language,
        lowLatency: Bool
    ) {
        guard translationTask != nil else { return }
        let isActive = volatileTranslationTask != nil || volatileTranslationStartTask != nil
        guard enabled != isActive else { return }
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
    private static let minVolatileTranslationLength = 3

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

    // 閾値超過後、末尾付近に句読点があれば区切りとして確定要求する。無ければ閾値の 1.5 倍まで
    // 保留し Speech 側の自然な final 発火を待つ (純関数・テスト対象)
    nonisolated static func shouldForceFinalize(text: String, threshold: Int) -> Bool {
        guard text.count >= threshold else { return false }
        let hardLimit = Int(Double(threshold) * forceFinalizeGraceMultiplier)
        if text.count >= hardLimit { return true }
        return text.suffix(forceFinalizePunctuationTailWindow)
            .contains { sentenceBreakPunctuation.contains($0) }
    }

    // 切れ目なく話し続けると isFinal が届かず翻訳が始まらないため強制確定で文を区切る。
    // 確定結果が届くまで再要求しない (volatile 更新ごとの重複要求を防ぐ)
    private func forceFinalizeIfOverflowing(volatile text: String) {
        guard !forcedFinalizeInFlight, Self.shouldForceFinalize(text: text, threshold: segmentThreshold)
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
            if let pending = self.pendingCorrectionRestart {
                self.pendingCorrectionRestart = nil
                self.startCorrectionWorker(inputLocale: pending.inputLocale, vocabulary: pending.vocabulary)
            }
        }
    }

    private func startTranslationWorker(
        resolvedSource: Locale.Language,
        resolvedTarget: Locale.Language,
        lowLatency: Bool
    ) {
        // ライブ字幕では滞留した古い文を訳す価値がないため、翻訳が追いつかない場合は
        // 新しい文を優先して古い待ち行列を捨てる (実測データが無いため保守的に 2 件までに絞り、
        // 最大遅延を短く抑える)
        let (sourceStream, sourceContinuation) = AsyncStream.makeStream(
            of: (text: String, generation: Int).self,
            bufferingPolicy: .bufferingNewest(2)
        )
        pendingSourceText = sourceContinuation

        // TranslationSession は non-Sendable のため、detached task 内でローカル所有して
        // actor 境界を越える sending を発生させない
        let state = self.state
        translationTask = Task.detached {
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
                        state.setStatusMessage(t("status.translation_model_not_installed"))
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
        translationTask?.cancel()
        translationTask = nil
        volatileTranslationTask?.cancel()
        volatileTranslationTask = nil
        volatileTranslationStartTask?.cancel()
        volatileTranslationStartTask = nil
        pruneTask?.cancel()
        pruneTask = nil
        state.isRunning = false
        // pruneTask も止まるため、追従訳を残すと失効せず表示に残り続ける
        state.clearVolatile()
    }
}
