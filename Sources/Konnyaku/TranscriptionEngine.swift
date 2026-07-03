import AVFoundation
import Foundation
import Speech

@MainActor
final class TranscriptionEngine {
    private(set) var transcriber: SpeechTranscriber?
    private(set) var analyzerFormat: AVAudioFormat?
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?

    // onDownloadProgress は DL 開始時に request の Progress を、完了時に nil を渡す
    // (nil 通知が無いと呼び出し側は pipeline 起動全体の完了までウィンドウを閉じられない)
    func prepare(
        locale requestedLocale: Locale,
        onDownloadProgress: ((Progress?) -> Void)? = nil
    ) async throws -> SpeechTranscriber {
        guard let locale = await SpeechTranscriber.supportedLocale(
            equivalentTo: requestedLocale
        ) else {
            throw KonnyakuError.speechUnsupported
        }
        // .fastResults を外すと volatile 結果の初出が数秒単位で遅れ、ライブ字幕として
        // 成立しないことを実測 (確定精度の差は eval で CER +0.6pp 程度、AI 補正層が吸収する)
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: []
        )
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            onDownloadProgress?(request.progress)
            try await request.downloadAndInstall()
            onDownloadProgress?(nil)
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber]
        ) else {
            throw KonnyakuError.audioFormatUnavailable
        }
        self.transcriber = transcriber
        self.analyzerFormat = format
        return transcriber
    }

    func start(contextualTerms: [String]) async throws -> AsyncStream<AnalyzerInput>.Continuation {
        guard let transcriber else {
            throw KonnyakuError.transcriberNotPrepared
        }
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        // カスタム語彙は解析開始前に確定している必要があるため、後付けの setContext ではなく
        // init の analysisContext で渡す。ただし eval では phrase biasing の効果を確認できて
        // おらず、語彙の実効的な反映は AI 補正プロンプト側 (CorrectionEngine) が担っている
        let context = AnalysisContext()
        if !contextualTerms.isEmpty {
            context.contextualStrings[.general] = contextualTerms
        }
        let analyzer = SpeechAnalyzer(
            inputSequence: stream,
            modules: [transcriber],
            options: nil,
            analysisContext: context
        )
        self.analyzer = analyzer
        self.inputContinuation = continuation
        return continuation
    }

    // 切れ目なく話し続けて isFinal が来ない長文を強制確定させる (認識は継続する)。
    // 失敗を返すのは caller が in-flight flag を解除するため
    func finalizeCurrentSegment() async -> Bool {
        // analyzer 不在の no-op を成功扱いにすると caller の flag 解除経路が欠ける
        guard let analyzer else { return false }
        do {
            try await analyzer.finalize(through: nil)
            return true
        } catch {
            debugLog("segment finalize error: \(error)")
            return false
        }
    }

    func stop() async {
        inputContinuation?.finish()
        inputContinuation = nil
        do {
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            debugLog("finalize error: \(error)")
        }
        analyzer = nil
    }
}
