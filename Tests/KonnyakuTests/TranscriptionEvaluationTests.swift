import AVFoundation
import Foundation
import FoundationModels
import Speech
import Testing

@testable import Konnyaku

// macOS の合成音声 (say) を ground truth 付きコーパスとして使う定量評価ハーネス。
// spoken (発話される生テキスト) と truth (字幕として望ましい整形後テキスト) を分離して
// フィラー除去・言い直し反映のような「原文と正解が異なる」補正を条件別 CER で評価できる。
// 実行に数十秒 + Speech / Apple Intelligence モデルを要するため通常の suite からは除外し、
// KONNYAKU_EVAL=1 swift test --filter TranscriptionEvaluation で明示実行する
private let evalEnabled = ProcessInfo.processInfo.environment["KONNYAKU_EVAL"] == "1"

@MainActor
struct TranscriptionEvaluationTests {
    struct Sentence {
        let id: String
        let category: String
        let spoken: String
        let truth: String

        init(id: String, category: String, spoken: String, truth: String? = nil) {
            self.id = id
            self.category = category
            self.spoken = spoken
            self.truth = truth ?? spoken
        }
    }

    static let corpus: [Sentence] = [
        Sentence(id: "hashi", category: "homophone", spoken: "橋の端を箸を持って歩いた"),
        Sentence(id: "kisha", category: "homophone", spoken: "貴社の記者が汽車で帰社した"),
        Sentence(id: "eisei", category: "homophone", spoken: "衛星放送で衛生管理の特集を見た"),
        Sentence(id: "hoken", category: "homophone", spoken: "保険の営業が保健の授業を見学した"),
        Sentence(
            id: "filler-demo", category: "filler",
            spoken: "えっと、今日はですね、まあ、新機能のデモをお見せします",
            truth: "今日は新機能のデモをお見せします"),
        Sentence(
            id: "filler-button", category: "filler",
            spoken: "あの、このボタンを、えっと、押すと設定画面が開きます",
            truth: "このボタンを押すと設定画面が開きます"),
        Sentence(
            id: "filler-deploy", category: "filler",
            spoken: "えっと、プルリクエストをマージしたら、まあ、すぐデプロイされます",
            truth: "プルリクエストをマージしたらすぐデプロイされます"),
        Sentence(
            id: "repair-asatte", category: "repair",
            spoken: "明日、じゃなくて明後日の会議で説明します",
            truth: "明後日の会議で説明します"),
        Sentence(
            id: "repair-plan", category: "repair",
            spoken: "この機能は無料、あ、違う、有料プランだけで使えます",
            truth: "この機能は有料プランだけで使えます"),
        Sentence(
            id: "tech-frameworks", category: "tech",
            spoken: "このアプリはスピーチアナライザーとファウンデーションモデルズを使っている"),
        Sentence(
            id: "tech-konnyaku", category: "tech",
            spoken: "コンニャクはほんやくコンニャク由来の字幕アプリだ"),
        Sentence(id: "num-date", category: "number", spoken: "2026年7月2日に34人が参加した"),
        Sentence(id: "num-price", category: "number", spoken: "料金は月額1200円で容量は50ギガバイトです"),
        Sentence(id: "plain-roadmap", category: "plain", spoken: "会議で製品のロードマップと課題を共有した"),
        Sentence(id: "plain-eval", category: "plain", spoken: "音声認識の精度を定量的に評価する"),
        Sentence(
            id: "plain-long", category: "plain",
            spoken: "資料を共有しますので、画面を見ながら、わからないところがあれば途中で質問してください"),
    ]

    // tech-* 文に含まれる、通常の言語モデルが出しにくい語
    static let vocabularyTerms = ["スピーチアナライザー", "ファウンデーションモデルズ", "コンニャク", "ほんやくコンニャク"]

    static let conditionNames = [
        "A:fast", "B:accurate", "C:vocabulary", "D:corrected", "E:vocab+corrected",
        "F:fast+vocab+corrected",
    ]

    @Test(.enabled(if: evalEnabled))
    func evaluateTranscriptionAccuracy() async throws {
        let audioDirectory = URL(fileURLWithPath: ".claude/tmp/eval-audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)

        let corrector = CorrectionEngine.isAvailable
            ? CorrectionEngine(languageName: "Japanese") : nil
        let vocabularyCorrector = CorrectionEngine.isAvailable
            ? CorrectionEngine(languageName: "Japanese", vocabulary: Self.vocabularyTerms) : nil

        var rows: [String] = []
        var totals: [String: (errors: Int, chars: Int)] = [:]
        var categoryTotals: [String: [String: (errors: Int, chars: Int)]] = [:]

        for sentence in Self.corpus {
            let audioURL = audioDirectory.appendingPathComponent("\(sentence.id).aiff")
            try Self.synthesize(sentence.spoken, to: audioURL)

            let fast = try await Self.transcribe(audioURL, fastResults: true, contextualTerms: [])
            let fastWithVocabulary = try await Self.transcribe(
                audioURL, fastResults: true, contextualTerms: Self.vocabularyTerms)
            let accurate = try await Self.transcribe(audioURL, fastResults: false, contextualTerms: [])
            let withVocabulary = try await Self.transcribe(
                audioURL, fastResults: false, contextualTerms: Self.vocabularyTerms)
            let corrected = corrector != nil ? await corrector!.correct(accurate) : accurate
            let vocabularyCorrected = vocabularyCorrector != nil
                ? await vocabularyCorrector!.correct(withVocabulary) : withVocabulary
            let fastVocabularyCorrected = vocabularyCorrector != nil
                ? await vocabularyCorrector!.correct(fastWithVocabulary) : fastWithVocabulary

            let conditions: [(name: String, hypothesis: String)] = [
                ("A:fast", fast),
                ("B:accurate", accurate),
                ("C:vocabulary", withVocabulary),
                ("D:corrected", corrected),
                ("E:vocab+corrected", vocabularyCorrected),
                ("F:fast+vocab+corrected", fastVocabularyCorrected),
            ]
            var cells: [String] = []
            for condition in conditions {
                let (errors, chars) = Self.editStats(truth: sentence.truth, hypothesis: condition.hypothesis)
                let total = totals[condition.name] ?? (0, 0)
                totals[condition.name] = (total.errors + errors, total.chars + chars)
                var byCategory = categoryTotals[sentence.category] ?? [:]
                let categoryTotal = byCategory[condition.name] ?? (0, 0)
                byCategory[condition.name] = (categoryTotal.errors + errors, categoryTotal.chars + chars)
                categoryTotals[sentence.category] = byCategory
                cells.append(String(format: "%.0f%%", Double(errors) / Double(max(chars, 1)) * 100))
            }
            rows.append("[\(sentence.category)] \(sentence.id): " + cells.joined(separator: " / "))
            rows.append("  truth: \(sentence.truth)")
            rows.append("  B:     \(accurate)")
            if withVocabulary != accurate {
                rows.append("  C:     \(withVocabulary)")
            }
            if corrected != accurate {
                rows.append("  D:     \(corrected)")
            }
            if vocabularyCorrected != corrected {
                rows.append("  E:     \(vocabularyCorrected)")
            }
            if fastVocabularyCorrected != vocabularyCorrected {
                rows.append("  F:     \(fastVocabularyCorrected)")
            }
        }

        print("===== KONNYAKU_EVAL 結果 (CER: \(Self.conditionNames.joined(separator: " / "))) =====")
        for row in rows {
            print(row)
        }
        print("----- カテゴリ別 CER -----")
        for category in ["homophone", "filler", "repair", "tech", "number", "plain"] {
            guard let byCondition = categoryTotals[category] else { continue }
            let cells = Self.conditionNames.map { name -> String in
                guard let total = byCondition[name] else { return "-" }
                return String(format: "%.1f%%", Double(total.errors) / Double(max(total.chars, 1)) * 100)
            }
            print("\(category): " + cells.joined(separator: " / "))
        }
        print("----- 全体 CER -----")
        for name in Self.conditionNames {
            if let total = totals[name] {
                let cer = Double(total.errors) / Double(max(total.chars, 1)) * 100
                print(String(format: "%@: %.2f%% (%d errors / %d chars)", name, cer, total.errors, total.chars))
            }
        }
        if corrector == nil {
            print("D/E は Apple Intelligence 不可のため補正なしと同一 (未評価)")
        }
        print("===== KONNYAKU_EVAL 終了 =====")
    }

    private struct SpeechSynthesisFailed: Error {
        let exitCode: Int32
    }

    private static func synthesize(_ text: String, to url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", "Kyoko", "-o", url.path, text]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SpeechSynthesisFailed(exitCode: process.terminationStatus)
        }
    }

    // アプリ本体と同じ「AsyncStream + init(analysisContext:) + AVAudioConverter」経路で
    // ファイルを流し込む (プロダクション経路の忠実な再現)
    private static func transcribe(
        _ url: URL,
        fastResults: Bool,
        contextualTerms: [String]
    ) async throws -> String {
        guard let locale = await SpeechTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: "ja-JP")
        ) else {
            throw KonnyakuError.speechUnsupported
        }
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: fastResults ? [.fastResults] : [],
            attributeOptions: []
        )
        // クリーンな環境でも動くよう、アプリ本体の prepare と同じく認識モデルを先に導入する
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber]
        ) else {
            throw KonnyakuError.audioFormatUnavailable
        }

        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
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

        let collector = Task {
            var output = ""
            for try await result in transcriber.results where result.isFinal {
                output += String(result.text.characters)
            }
            return output
        }

        let file = try AVAudioFile(forReading: url)
        let fileFormat = file.processingFormat
        guard let converter = AVAudioConverter(from: fileFormat, to: analyzerFormat) else {
            throw KonnyakuError.audioConverterUnavailable
        }
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: 8192) else {
                throw KonnyakuError.audioConverterUnavailable
            }
            try file.read(into: buffer)
            if buffer.frameLength == 0 {
                break
            }
            if let converted = AudioCaptureEngine.convert(buffer, with: converter, to: analyzerFormat) {
                continuation.yield(AnalyzerInput(buffer: converted))
            }
        }
        continuation.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await collector.value
    }

    // 表記ゆれ (句読点・空白・全半角) を正規化した文字列同士の Levenshtein 距離。
    // 返り値は (編集距離, 正解文字数) で CER = 編集距離 / 正解文字数
    private static func editStats(truth: String, hypothesis: String) -> (Int, Int) {
        let normalizedTruth = normalize(truth)
        let normalizedHypothesis = normalize(hypothesis)
        return (levenshtein(normalizedTruth, normalizedHypothesis), normalizedTruth.count)
    }

    private static func normalize(_ text: String) -> [Character] {
        Array(text.precomposedStringWithCompatibilityMapping.filter { $0.isLetter || $0.isNumber })
    }

    private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
