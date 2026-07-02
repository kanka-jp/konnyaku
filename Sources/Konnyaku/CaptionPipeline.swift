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
    private var pruneTask: Task<Void, Never>?
    private var pendingCorrection: AsyncStream<String>.Continuation?
    private var pendingSourceText: AsyncStream<String>.Continuation?
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
        correctionEnabled: Bool,
        contextualTerms: [String]
    ) async throws {
        let transcriber = try await transcription.prepare(locale: inputLocale)
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
            startTranslationWorker(inputLanguage: inputLocale.language, outputLanguage: outputLanguage)
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
                    guard text.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
                    if result.isFinal {
                        debugLog("final arrived (len=\(text.count))\(logContentSuffix(text))")
                        self.state.appendFinalSource(text)
                        // 補正 worker がいる場合は補正後テキストが表示差し替えと翻訳を担う
                        if let pendingCorrection = self.pendingCorrection {
                            self.correctionBacklog += 1
                            pendingCorrection.yield(text)
                        } else {
                            self.pendingSourceText?.yield(text)
                        }
                    } else {
                        self.logVolatileProgress(text)
                        self.state.setVolatileSource(text)
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
        let (stream, continuation) = AsyncStream.makeStream(of: String.self)
        pendingCorrection = continuation

        correctionTask = Task { [weak self] in
            for await raw in stream {
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
                self.pendingSourceText?.yield(corrected)
            }
        }
    }

    private func startTranslationWorker(inputLanguage: Locale.Language, outputLanguage: Locale.Language) {
        // ライブ字幕では滞留した古い文を訳す価値がないため、翻訳が追いつかない場合は
        // 新しい文を優先して古い待ち行列を捨てる (無制限バッファによる遅延蓄積も防ぐ)
        let (sourceStream, sourceContinuation) = AsyncStream.makeStream(
            of: String.self,
            bufferingPolicy: .bufferingNewest(4)
        )
        pendingSourceText = sourceContinuation

        // TranslationSession は non-Sendable のため、detached task 内でローカル所有して
        // actor 境界を越える sending を発生させない
        let state = self.state
        translationTask = Task.detached {
            let pair = await TranslationSupport.resolvePair(input: inputLanguage, output: outputLanguage)
            let session = TranslationSupport.makeSession(source: pair.source, target: pair.target)
            do {
                // モデルを事前ロードして初回翻訳の待ちを短縮する
                let prepareStart = ContinuousClock.now
                try await session.prepareTranslation()
                debugLog("prepareTranslation ok in \(ContinuousClock.now - prepareStart)")
            } catch {
                debugLog("prepareTranslation error: \(error)")
            }
            for await sourceText in sourceStream {
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
                        state.appendTranslation(translated)
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
        recognitionTask?.cancel()
        recognitionTask = nil
        correctionTask?.cancel()
        correctionTask = nil
        translationTask?.cancel()
        translationTask = nil
        pruneTask?.cancel()
        pruneTask = nil
        state.isRunning = false
        state.setVolatileSource("")
    }
}
