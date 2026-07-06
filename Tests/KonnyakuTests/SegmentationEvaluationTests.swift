import AVFoundation
import Foundation
import Speech
import Testing
import Translation

@testable import Konnyaku

// セグメンテーション (強制確定) ポリシーの定量評価ハーネス。全 SegmentationPolicy を
// 同一音声・同一モデルで A/B 比較する (指標定義と gate を置かない理由は
// docs/DESIGN.md「定量評価ハーネス」参照)。音声は常に実時間ペーシングで流す:
// faster-than-realtime だと強制確定の finalize が全 audio 解析済み後に着地して
// 1 セグメントに潰れ、live の区切り挙動を再現できないことを実測済み。
// 実行: KONNYAKU_EVAL=1 swift test --filter SegmentationEvaluation
private let evalEnabled = ProcessInfo.processInfo.environment["KONNYAKU_EVAL"] == "1"

struct SegmentationEvaluationTests {
    // 節 (訳出単位) ごとの spoken / 参照訳 / 直後ポーズを持つ複数文コーパス。
    // parts の区切りが境界メトリクスの ground truth になる
    struct Monologue {
        struct Part {
            let spoken: String
            let referenceEN: String
            // 0 なら次節と連続合成し、acoustic な切れ目を意図的に作らない
            let pauseAfterMs: Int

            init(_ spoken: String, _ referenceEN: String, pauseAfterMs: Int = 0) {
                self.spoken = spoken
                self.referenceEN = referenceEN
                self.pauseAfterMs = pauseAfterMs
            }
        }

        let id: String
        let category: String
        let parts: [Part]

        var spokenJoined: String { parts.map(\.spoken).joined() }
        var referenceJoined: String { parts.map(\.referenceEN).joined(separator: " ") }

        // 参照境界 = 正規化後テキストにおける parts の累積オフセット (末尾は自明一致のため除外)
        var referenceBoundaries: [Int] {
            var offsets: [Int] = []
            var cumulative = 0
            for part in parts.dropLast() {
                cumulative += EvalMetrics.normalize(part.spoken).count
                offsets.append(cumulative)
            }
            return offsets
        }
    }

    // runon: 接続助詞で節が連鎖し句読点も acoustic pause も無い、強制確定頼みのストレステスト。
    // paused: 節間に既知長の無音を置いた講演調 (ポーズ境界の ground truth)。
    // lecture: 句読点 + 軽いポーズの読み上げ調 (中間形)
    static let monologues: [Monologue] = [
        Monologue(
            id: "runon-feature", category: "runon",
            parts: [
                .init(
                    "今日は新しい字幕機能について説明したいんですけど",
                    "Today I'd like to explain the new caption feature,"),
                .init(
                    "去年のリリースでは字幕が読みにくいという意見が多かったので",
                    "and since we received a lot of feedback last year that the captions were hard to read,"),
                .init(
                    "表示の仕組みを最初から作り直すことにして",
                    "we decided to rebuild the display system from scratch,"),
                .init(
                    "今回はその結果をデモを交えながら紹介します",
                    "so this time I will present the results with a demo."),
            ]),
        Monologue(
            id: "runon-schedule", category: "runon",
            parts: [
                .init(
                    "来月の予定を確認したところ会議が三つ重なっていて",
                    "When I checked next month's schedule, three meetings overlapped,"),
                .init(
                    "どれも動かせないと言われたから",
                    "and I was told none of them could be moved,"),
                .init(
                    "先にリリースの作業を今週中に終わらせておかないと",
                    "so unless we finish the release work within this week,"),
                .init(
                    "あとで全部の作業が止まってしまいます",
                    "all of the work will be blocked later."),
            ]),
        Monologue(
            id: "paused-intro", category: "paused",
            parts: [
                .init(
                    "こんにちは今日はお集まりいただきありがとうございます",
                    "Hello, thank you all for gathering today.",
                    pauseAfterMs: 500),
                .init(
                    "これから一時間ほど製品のロードマップを説明します",
                    "From now on I will spend about an hour explaining the product roadmap.",
                    pauseAfterMs: 500),
                .init(
                    "途中で質問があればいつでも聞いてください",
                    "If you have questions along the way, please ask at any time."),
            ]),
        Monologue(
            id: "lecture-caption", category: "lecture",
            parts: [
                .init(
                    "音声認識の結果は、まず画面の上の段に表示されます",
                    "The speech recognition result is shown first on the upper line of the screen.",
                    pauseAfterMs: 300),
                .init(
                    "翻訳が終わると、下の段に英語の字幕が追加されます",
                    "When the translation finishes, an English caption is added on the lower line.",
                    pauseAfterMs: 300),
                .init(
                    "この二段構成で、話し手の言葉と翻訳を同時に確認できます",
                    "With this two-line layout, you can check the speaker's words and the translation at the same time."),
            ]),
    ]

    // 仮説境界を参照座標へ射影して比較するときの許容窓 (正規化文字数)
    static let boundaryTolerance = 3
    // 追従訳へ流す volatile の最小長 (CaptionPipeline.minVolatileTranslationLength と対)
    static let minVolatileLength = 3

    struct FinalSegment {
        let text: String
        let forced: Bool
        let audioStart: Double?
        let audioEnd: Double?
        // replay 開始からの wall-clock 到着時刻 (秒)。arrival - audioEnd = 確定遅延
        let wallClockArrival: Double?
    }

    struct ReplayResult {
        var finals: [FinalSegment] = []
        // final ごとに、その final 到着までに観測した volatile テキスト列 (erasure 計算用)
        var volatileRuns: [[String]] = []
    }

    // CaptionPipeline.recognitionTask のセグメンテーション関連部分の再現。
    // CaptionPipeline 本体を使わないのは AudioCaptureEngine (実マイク) との結合と、
    // 追従訳 worker の bufferingNewest drop がタイミング非決定でメトリクスの再現性を
    // 落とすため。判定は同一の SegmentationPolicy 実装を共有する
    static func replay(
        audioURL: URL, policy: SegmentationPolicy, threshold: Int
    ) async throws -> ReplayResult {
        guard let locale = await SpeechTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: "ja-JP")
        ) else {
            throw KonnyakuError.speechUnsupported
        }
        // reportingOptions はプロダクション (TranscriptionEngine.prepare) と同一。
        // audioTimeRange は audio 時間軸メトリクス用の eval 専用追加
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange]
        )
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber]
        ) else {
            throw KonnyakuError.audioFormatUnavailable
        }
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let analyzer = SpeechAnalyzer(inputSequence: stream, modules: [transcriber], options: nil)

        let replayStart = ContinuousClock.now
        let collector = Task {
            var result = ReplayResult()
            var currentVolatiles: [String] = []
            var forcedInFlight = false
            for try await item in transcriber.results {
                let wasForced = forcedInFlight
                if item.isFinal {
                    forcedInFlight = false
                }
                let text = String(item.text.characters)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard text.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
                if item.isFinal {
                    let range = Self.audioRange(of: item.text)
                    let elapsed = (ContinuousClock.now - replayStart).components
                    let arrival = Double(elapsed.seconds) + Double(elapsed.attoseconds) * 1e-18
                    result.finals.append(FinalSegment(
                        text: text,
                        forced: wasForced,
                        audioStart: range?.start,
                        audioEnd: range?.end,
                        wallClockArrival: arrival
                    ))
                    result.volatileRuns.append(currentVolatiles)
                    currentVolatiles = []
                } else {
                    if text.count >= Self.minVolatileLength {
                        currentVolatiles.append(text)
                    }
                    if !forcedInFlight,
                        policy.shouldForceFinalize(text: text, threshold: threshold)
                    {
                        forcedInFlight = true
                        // プロダクション同様、結果ループを塞がないよう別 Task で要求する
                        // (この場で await すると final の消費が止まり deadlock する)。
                        // 失敗時の flag 解除は省略 (replay では次の自然 final が解除する)
                        Task { try? await analyzer.finalize(through: nil) }
                    }
                }
            }
            return result
        }

        try await EvalAudio.feed(
            url: audioURL, into: continuation, analyzerFormat: analyzerFormat,
            pacedRealtime: true)
        continuation.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await collector.value
    }

    private static func audioRange(of text: AttributedString) -> (start: Double, end: Double)? {
        var start: Double?
        var end: Double?
        for run in text.runs {
            guard let range = run.audioTimeRange else { continue }
            start = min(start ?? range.start.seconds, range.start.seconds)
            end = max(end ?? range.end.seconds, range.end.seconds)
        }
        guard let start, let end else { return nil }
        return (start, end)
    }

    // TranslationSession が test プロセスで使えるかの独立した診断。本命の evaluate が
    // chrF を出せない時、原因が翻訳環境かハーネスのバグかを切り分ける
    @Test(.enabled(if: evalEnabled))
    func translationSessionSmoke() async throws {
        let pair = await TranslationSupport.resolvePair(
            input: Locale.Language(identifier: "ja"),
            output: Locale.Language(identifier: "en"))
        let session = TranslationSupport.makeSession(
            source: pair.source, target: pair.target, lowLatency: false)
        try await session.prepareTranslation()
        let translated = try await session.translate("こんにちは、今日は良い天気です。").targetText
        print("translationSessionSmoke: \(translated)")
        #expect(!translated.isEmpty)
    }

    @Test(.enabled(if: evalEnabled))
    func evaluateSegmentationPolicies() async throws {
        let audioDirectory = URL(fileURLWithPath: ".claude/tmp/eval-audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)

        // 翻訳が使えない環境では chrF / 翻訳 erasure を欠測 (nil) にして他指標だけ出す
        let pair = await TranslationSupport.resolvePair(
            input: Locale.Language(identifier: "ja"),
            output: Locale.Language(identifier: "en"))
        let session = TranslationSupport.makeSession(
            source: pair.source, target: pair.target, lowLatency: false)
        var translationAvailable = true
        do {
            try await session.prepareTranslation()
            _ = try await session.translate("テスト").targetText
        } catch {
            translationAvailable = false
            print("translation unavailable in eval process: \(error)")
        }

        var records: [EvalRecord] = []
        for monologue in Self.monologues {
            let audioURL = try Self.synthesizeMonologue(monologue, in: audioDirectory)
            for policy in SegmentationPolicy.allCases {
                let replay = try await Self.replay(
                    audioURL: audioURL, policy: policy,
                    threshold: CaptionPipeline.cjkSegmentThreshold)
                let record = try await Self.evaluate(
                    monologue: monologue, policy: policy, replay: replay,
                    session: translationAvailable ? session : nil)
                records.append(record)

                // ハーネス自壊検知のみ assert する (品質の絶対値 gate は置かない)
                #expect(!replay.finals.isEmpty, "no finals for \(monologue.id) / \(policy)")
                #expect(
                    record.cer < 0.30,
                    "CER \(record.cer) too high for \(monologue.id) / \(policy) — replay 破損の疑い")
            }
        }

        Self.printReport(records)
        try Self.writeJSON(records)
    }

    // pauseAfterMs == 0 の連続 parts は 1 クリップに連続合成し (say のクリップ末尾無音で
    // 意図しない切れ目を作らない)、pause 指定位置だけ既知長の無音を挟む
    private static func synthesizeMonologue(
        _ monologue: Monologue, in directory: URL
    ) throws -> URL {
        var clips: [(url: URL, silenceAfterMs: Int)] = []
        var chunkText = ""
        var chunkIndex = 0
        func flush(silenceAfterMs: Int) throws {
            guard !chunkText.isEmpty else { return }
            let clipURL = directory.appendingPathComponent(
                "\(monologue.id)-part\(chunkIndex).aiff")
            try EvalAudio.synthesize(chunkText, to: clipURL)
            clips.append((clipURL, silenceAfterMs))
            chunkText = ""
            chunkIndex += 1
        }
        for part in monologue.parts {
            chunkText += part.spoken
            if part.pauseAfterMs > 0 {
                try flush(silenceAfterMs: part.pauseAfterMs)
            }
        }
        try flush(silenceAfterMs: 0)
        let outputURL = directory.appendingPathComponent("\(monologue.id).aiff")
        try? FileManager.default.removeItem(at: outputURL)
        try EvalAudio.concatenate(clips: clips, to: outputURL)
        return outputURL
    }

    struct EvalRecord: Codable {
        let monologue: String
        let category: String
        let policy: String
        let segments: Int
        let forcedSegments: Int
        let cer: Double
        let boundaryPrecision: Double
        let boundaryRecall: Double
        let boundaryF1: Double
        let meanSegmentChars: Double
        let maxSegmentChars: Int
        let meanSegmentAudioSeconds: Double?
        let meanFinalizationLagSeconds: Double?
        let chrF: Double?
        let sourceErasedChars: Int
        let translationErasedChars: Int?
        let finalTexts: [String]
        let translatedTexts: [String]?
    }

    private static func evaluate(
        monologue: Monologue,
        policy: SegmentationPolicy,
        replay: ReplayResult,
        session: TranslationSession?
    ) async throws -> EvalRecord {
        let hypothesisJoined = replay.finals.map(\.text).joined()
        let normalizedHypothesis = EvalMetrics.normalize(hypothesisJoined)
        let normalizedReference = EvalMetrics.normalize(monologue.spokenJoined)
        let cer = Double(EvalMetrics.levenshtein(normalizedHypothesis, normalizedReference))
            / Double(max(normalizedReference.count, 1))

        // 仮説セグメント境界 (正規化累積オフセット、末尾除外) を参照座標へ射影して比較
        let projection = EvalMetrics.alignmentProjection(
            hypothesis: normalizedHypothesis, reference: normalizedReference)
        var hypothesisBoundaries: [Int] = []
        var cumulative = 0
        for segment in replay.finals.dropLast() {
            cumulative += EvalMetrics.normalize(segment.text).count
            hypothesisBoundaries.append(projection[min(cumulative, projection.count - 1)])
        }
        let boundary = EvalMetrics.boundaryScore(
            hypothesis: hypothesisBoundaries,
            reference: monologue.referenceBoundaries,
            tolerance: Self.boundaryTolerance)

        let segmentLengths = replay.finals.map { $0.text.count }
        let audioLengths = replay.finals.compactMap { segment -> Double? in
            guard let start = segment.audioStart, let end = segment.audioEnd else { return nil }
            return end - start
        }
        let lags = replay.finals.compactMap { segment -> Double? in
            guard let arrival = segment.wallClockArrival, let end = segment.audioEnd else {
                return nil
            }
            return arrival - end
        }

        var chrF: Double?
        var translatedTexts: [String]?
        var translationErased: Int?
        if let session {
            var translations: [String] = []
            for segment in replay.finals {
                translations.append(try await session.translate(segment.text).targetText)
            }
            translatedTexts = translations
            chrF = EvalMetrics.chrF(
                hypothesis: translations.joined(separator: " "),
                reference: monologue.referenceJoined)

            // 追従訳の flicker: volatile 列を drop なしで逐次翻訳した表示列の erasure。
            // 連続重複は表示が変わらないため除外する
            var erased = 0
            for run in replay.volatileRuns {
                var deduped: [String] = []
                for text in run where text != deduped.last {
                    deduped.append(text)
                }
                var translatedRun: [String] = []
                for text in deduped {
                    translatedRun.append(try await session.translate(text).targetText)
                }
                erased += EvalMetrics.erasedCharacters(updates: translatedRun)
            }
            translationErased = erased
        }

        let sourceErased = replay.volatileRuns.reduce(0) {
            $0 + EvalMetrics.erasedCharacters(updates: $1)
        }

        return EvalRecord(
            monologue: monologue.id,
            category: monologue.category,
            policy: String(describing: policy),
            segments: replay.finals.count,
            forcedSegments: replay.finals.filter(\.forced).count,
            cer: cer,
            boundaryPrecision: boundary.precision,
            boundaryRecall: boundary.recall,
            boundaryF1: boundary.f1,
            meanSegmentChars: segmentLengths.isEmpty
                ? 0 : Double(segmentLengths.reduce(0, +)) / Double(segmentLengths.count),
            maxSegmentChars: segmentLengths.max() ?? 0,
            meanSegmentAudioSeconds: audioLengths.isEmpty
                ? nil : audioLengths.reduce(0, +) / Double(audioLengths.count),
            meanFinalizationLagSeconds: lags.isEmpty
                ? nil : lags.reduce(0, +) / Double(lags.count),
            chrF: chrF,
            sourceErasedChars: sourceErased,
            translationErasedChars: translationErased,
            finalTexts: replay.finals.map(\.text),
            translatedTexts: translatedTexts
        )
    }

    private static func format(_ value: Double?, _ digits: Int = 1) -> String {
        guard let value else { return "-" }
        return String(format: "%.\(digits)f", value)
    }

    private static func formatSeconds(_ value: Double?) -> String {
        value.map { String(format: "%.2fs", $0) } ?? "-"
    }

    private static func printReport(_ records: [EvalRecord]) {
        print("===== KONNYAKU_EVAL segmentation 結果 =====")
        for record in records {
            print(
                "[\(record.category)] \(record.monologue) / \(record.policy): "
                    + "seg=\(record.segments) (forced=\(record.forcedSegments)) "
                    + "boundary P/R/F1=\(format(record.boundaryPrecision, 2))/"
                    + "\(format(record.boundaryRecall, 2))/\(format(record.boundaryF1, 2)) "
                    + "CER=\(format(record.cer * 100, 1))% "
                    + "len(mean/max)=\(format(record.meanSegmentChars, 1))/\(record.maxSegmentChars) "
                    + "audio(mean)=\(formatSeconds(record.meanSegmentAudioSeconds)) "
                    + "lag(mean)=\(formatSeconds(record.meanFinalizationLagSeconds)) "
                    + "chrF=\(format(record.chrF, 1)) "
                    + "erased(src/trans)=\(record.sourceErasedChars)/"
                    + "\(record.translationErasedChars.map(String.init) ?? "-")")
            for (index, text) in record.finalTexts.enumerated() {
                let translated = record.translatedTexts?[index]
                print("  seg\(index): \(text)\(translated.map { " → \($0)" } ?? "")")
            }
        }
        print("----- policy 別集計 -----")
        let policies = Set(records.map(\.policy)).sorted()
        for policy in policies {
            let subset = records.filter { $0.policy == policy }
            let f1 = subset.map(\.boundaryF1).reduce(0, +) / Double(subset.count)
            let chrFValues = subset.compactMap(\.chrF)
            let chrFMean = chrFValues.isEmpty
                ? nil : chrFValues.reduce(0, +) / Double(chrFValues.count)
            let forced = subset.map(\.forcedSegments).reduce(0, +)
            let segments = subset.map(\.segments).reduce(0, +)
            print(
                "\(policy): boundary F1=\(format(f1, 3)) chrF=\(format(chrFMean, 1)) "
                    + "forced/seg=\(forced)/\(segments)")
        }
        print("===== KONNYAKU_EVAL segmentation 終了 =====")
    }

    private static func writeJSON(_ records: [EvalRecord]) throws {
        let directory = URL(fileURLWithPath: ".claude/tmp/eval-results", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let timestamp = Int(Date().timeIntervalSince1970)
        let url = directory.appendingPathComponent("segmentation-\(timestamp).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(records).write(to: url)
        print("JSON written: \(url.path)")
    }
}
