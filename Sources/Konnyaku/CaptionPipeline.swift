import Foundation
import Speech

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
    private var pruneTask: Task<Void, Never>?
    private var pendingCorrection: AsyncStream<(text: String, generation: Int)>.Continuation?
    private var pendingSourceText: AsyncStream<(text: String, generation: Int)>.Continuation?
    private var pendingVolatileText: AsyncStream<(text: String, generation: Int)>.Continuation?
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

    func start(
        inputLocale: Locale,
        outputLanguage: Locale.Language,
        translationEnabled: Bool,
        useLowLatencyTranslation: Bool,
        volatileTranslationEnabled: Bool,
        correctionEnabled: Bool,
        contextualTerms: [String],
        onSpeechModelDownload: ((Progress?) -> Void)? = nil
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
                inputLanguage: inputLocale.language,
                outputLanguage: outputLanguage,
                lowLatency: useLowLatencyTranslation
            )
            // worker を起動しなければ pendingVolatileText が nil のまま yield が no-op になる
            if volatileTranslationEnabled {
                startVolatileTranslationWorker(
                    inputLanguage: inputLocale.language,
                    outputLanguage: outputLanguage,
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
        inputLanguage: Locale.Language,
        outputLanguage: Locale.Language,
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
            let pair = await TranslationSupport.resolvePair(input: inputLanguage, output: outputLanguage)
            let session = TranslationSupport.makeSession(
                source: pair.source, target: pair.target, lowLatency: lowLatency)
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

    // 切れ目なく話し続けると isFinal が届かず翻訳が始まらないため強制確定で文を区切る。
    // 確定結果が届くまで再要求しない (volatile 更新ごとの重複要求を防ぐ)
    private func forceFinalizeIfOverflowing(volatile text: String) {
        guard !forcedFinalizeInFlight, text.count >= segmentThreshold else { return }
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
                self.state.replaceFinalSource(raw, with: corrected)
                self.pendingSourceText?.yield((corrected, generation))
            }
        }
    }

    private func startTranslationWorker(
        inputLanguage: Locale.Language,
        outputLanguage: Locale.Language,
        lowLatency: Bool
    ) {
        // ライブ字幕では滞留した古い文を訳す価値がないため、翻訳が追いつかない場合は
        // 新しい文を優先して古い待ち行列を捨てる (無制限バッファによる遅延蓄積も防ぐ)
        let (sourceStream, sourceContinuation) = AsyncStream.makeStream(
            of: (text: String, generation: Int).self,
            bufferingPolicy: .bufferingNewest(4)
        )
        pendingSourceText = sourceContinuation

        // TranslationSession は non-Sendable のため、detached task 内でローカル所有して
        // actor 境界を越える sending を発生させない
        let state = self.state
        translationTask = Task.detached {
            let pair = await TranslationSupport.resolvePair(input: inputLanguage, output: outputLanguage)
            debugLog("translation strategy: \(lowLatency ? "lowLatency" : "highFidelity")")
            let session = TranslationSupport.makeSession(
                source: pair.source, target: pair.target, lowLatency: lowLatency)
            do {
                // モデルを事前ロードして初回翻訳の待ちを短縮する
                let prepareStart = ContinuousClock.now
                try await session.prepareTranslation()
                debugLog("prepareTranslation ok in \(ContinuousClock.now - prepareStart)")
            } catch {
                debugLog("prepareTranslation error: \(error)")
            }
            for await (sourceText, generation) in sourceStream {
                // キャンセル後に in-flight の翻訳結果で次セッションの state を汚さない
                if Task.isCancelled { return }
                do {
                    debugLog("translate start (len=\(sourceText.count))\(logContentSuffix(sourceText))")
                    let translateStart = ContinuousClock.now
                    let translated = try await session.translate(sourceText).targetText
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
        translationTask?.cancel()
        translationTask = nil
        volatileTranslationTask?.cancel()
        volatileTranslationTask = nil
        pruneTask?.cancel()
        pruneTask = nil
        state.isRunning = false
        // pruneTask も止まるため、追従訳を残すと失効せず表示に残り続ける
        state.clearVolatile()
    }
}
