import AVFoundation
import Foundation
import Speech

@testable import Konnyaku

// KONNYAKU_EVAL 系テスト (TranscriptionEvaluationTests / SegmentationEvaluationTests) で
// 共有する合成音声・ファイル replay のヘルパー
enum EvalAudio {
    struct SpeechSynthesisFailed: Error {
        let exitCode: Int32
    }

    struct AudioConcatenationFailed: Error {
        let reason: String
    }

    static func synthesize(_ text: String, to url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", "Kyoko", "-o", url.path, text]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SpeechSynthesisFailed(exitCode: process.terminationStatus)
        }
    }

    // 個別合成したクリップを、指定長の無音を挟んで 1 本に連結する。say のタグ埋め込みと
    // 違い無音長が正確に既知になるため、ポーズ位置・長さの ground truth として使える
    static func concatenate(clips: [(url: URL, silenceAfterMs: Int)], to url: URL) throws {
        guard let first = clips.first else {
            throw AudioConcatenationFailed(reason: "no clips")
        }
        let firstFile = try AVAudioFile(forReading: first.url)
        let format = firstFile.processingFormat
        let output = try AVAudioFile(forWriting: url, settings: firstFile.fileFormat.settings)
        for clip in clips {
            let file = try AVAudioFile(forReading: clip.url)
            guard file.processingFormat == format else {
                throw AudioConcatenationFailed(reason: "format mismatch: \(clip.url.lastPathComponent)")
            }
            while file.framePosition < file.length {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else {
                    throw AudioConcatenationFailed(reason: "buffer allocation failed")
                }
                try file.read(into: buffer)
                if buffer.frameLength == 0 {
                    break
                }
                try output.write(from: buffer)
            }
            if clip.silenceAfterMs > 0 {
                // 切り捨てだと ms がサンプルレートで割り切れないとき無音が sub-sample 短くなる
                let frames = AVAudioFrameCount(
                    (format.sampleRate * Double(clip.silenceAfterMs) / 1000).rounded())
                guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
                    let channels = silence.floatChannelData
                else {
                    throw AudioConcatenationFailed(reason: "silence buffer allocation failed")
                }
                silence.frameLength = frames
                for channel in 0..<Int(format.channelCount) {
                    channels[channel].update(repeating: 0, count: Int(frames))
                }
                try output.write(from: silence)
            }
        }
    }

    // アプリ本体と同じ AVAudioConverter 経路でファイルを analyzer の入力へ流し込む。
    // pacedRealtime は live のタイミング再現が要る評価 (区切り判定・レイテンシ測定) 用で、
    // タイミング無関係な CER 評価は off (faster-than-realtime) で回す。
    // onChunkFed は各バッファ供給直後に供給済み累積秒を通知する (pauseAware の
    // ポーズ判定は無音中に volatile が来ず判定機会が無いため、供給側で発火させる)
    static func feed(
        url: URL,
        into continuation: AsyncStream<AnalyzerInput>.Continuation,
        analyzerFormat: AVAudioFormat,
        pacedRealtime: Bool = false,
        onChunkFed: (@Sendable (TimeInterval) -> Void)? = nil
    ) async throws {
        let file = try AVAudioFile(forReading: url)
        let sourceFormat = file.processingFormat
        guard let converter = AVAudioConverter(from: sourceFormat, to: analyzerFormat) else {
            throw KonnyakuError.audioConverterUnavailable
        }
        var fedSeconds: TimeInterval = 0
        while file.framePosition < file.length {
            // production tap (AudioCaptureEngine の bufferSize: 4096) と同じ粒度で届ける
            // (粗いチャンクだと paced 時の配信間隔が live の 2 倍になり lag 計測がずれる)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: 4096) else {
                throw KonnyakuError.audioConverterUnavailable
            }
            try file.read(into: buffer)
            if buffer.frameLength == 0 {
                break
            }
            if pacedRealtime {
                // live の tap はバッファ取得完了後 (= バッファ末尾の時刻) に届くため、
                // 先に実時間ぶん待ってから yield する (yield → sleep の順だと解析が
                // live より最大 1 バッファ分先行し、確定遅延が過小計上される)
                let seconds = Double(buffer.frameLength) / sourceFormat.sampleRate
                try await Task.sleep(for: .seconds(seconds))
            }
            if let converted = AudioCaptureEngine.convert(buffer, with: converter, to: analyzerFormat) {
                continuation.yield(AnalyzerInput(buffer: converted))
                fedSeconds += Double(buffer.frameLength) / sourceFormat.sampleRate
                onChunkFed?(fedSeconds)
            } else {
                // 黙殺すると timing / CER 計測が静かに歪むため可視化する (best-effort 続行)
                print("EvalAudio.feed: dropped unconvertible buffer at frame \(file.framePosition)")
            }
        }
    }
}

// 評価メトリクス (全て純関数、EvalMetricsTests でユニットテスト対象)
enum EvalMetrics {
    // 表記ゆれ (句読点・空白・全半角) を正規化した文字列比較の共通前処理
    static func normalize(_ text: String) -> [Character] {
        Array(text.precomposedStringWithCompatibilityMapping.filter { $0.isLetter || $0.isNumber })
    }

    static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
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

    // 仮説側の各文字境界オフセット (0...hypothesis.count) を、最適編集パス上で対応する
    // 参照側オフセットへ射影する。ASR 誤りを含む仮説セグメント境界を参照座標系へ移して
    // boundaryScore と比較するために使う。O(n·m) full matrix だが対象は字幕 1 発話分で小さい
    static func alignmentProjection(hypothesis a: [Character], reference b: [Character]) -> [Int] {
        let n = a.count
        let m = b.count
        if n == 0 { return [0] }
        if m == 0 { return Array(repeating: 0, count: n + 1) }
        var distance = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for j in 0...m { distance[0][j] = j }
        for i in 1...n {
            distance[i][0] = i
            for j in 1...m {
                let substitution = distance[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                distance[i][j] = min(distance[i - 1][j] + 1, distance[i][j - 1] + 1, substitution)
            }
        }
        var projection = Array(repeating: 0, count: n + 1)
        var i = n
        var j = m
        projection[n] = m
        while i > 0 || j > 0 {
            projection[i] = j
            if i > 0, j > 0,
                distance[i][j] == distance[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
            {
                i -= 1
                j -= 1
            } else if i > 0, distance[i][j] == distance[i - 1][j] + 1 {
                i -= 1
            } else {
                j -= 1
            }
        }
        projection[0] = 0
        return projection
    }

    // sacrebleu 互換の chrF (Popović 2015): char 1..6-gram、β=2、空白除去、
    // effective-order smoothing (hyp/ref 双方に n-gram が存在する order のみ P/R 平均に算入)
    static func chrF(
        hypothesis: String, reference: String, charOrder: Int = 6, beta: Double = 2
    ) -> Double {
        let hyp = Array(hypothesis.filter { !$0.isWhitespace })
        let ref = Array(reference.filter { !$0.isWhitespace })
        var effectiveOrders = 0
        var precisionSum = 0.0
        var recallSum = 0.0
        for order in 1...charOrder {
            let hypCounts = ngramCounts(hyp, order: order)
            let refCounts = ngramCounts(ref, order: order)
            let hypTotal = hypCounts.values.reduce(0, +)
            let refTotal = refCounts.values.reduce(0, +)
            guard hypTotal > 0, refTotal > 0 else { continue }
            var matches = 0
            for (gram, count) in hypCounts {
                matches += min(count, refCounts[gram] ?? 0)
            }
            precisionSum += Double(matches) / Double(hypTotal)
            recallSum += Double(matches) / Double(refTotal)
            effectiveOrders += 1
        }
        guard effectiveOrders > 0 else { return 0 }
        let precision = precisionSum / Double(effectiveOrders)
        let recall = recallSum / Double(effectiveOrders)
        let factor = beta * beta
        let denominator = factor * precision + recall
        guard denominator > 0 else { return 0 }
        return 100 * (1 + factor) * precision * recall / denominator
    }

    private static func ngramCounts(_ characters: [Character], order: Int) -> [String: Int] {
        guard characters.count >= order else { return [:] }
        var counts: [String: Int] = [:]
        for start in 0...(characters.count - order) {
            counts[String(characters[start..<(start + order)]), default: 0] += 1
        }
        return counts
    }

    struct BoundaryScore {
        let matched: Int
        let hypothesisCount: Int
        let referenceCount: Int

        var precision: Double {
            hypothesisCount > 0 ? Double(matched) / Double(hypothesisCount) : 0
        }
        var recall: Double {
            referenceCount > 0 ? Double(matched) / Double(referenceCount) : 0
        }
        var f1: Double {
            precision + recall > 0 ? 2 * precision * recall / (precision + recall) : 0
        }
    }

    // 境界オフセット同士を許容窓つきで 1 対 1 マッチング (両側ソート済み前提の貪欲法)
    static func boundaryScore(hypothesis: [Int], reference: [Int], tolerance: Int) -> BoundaryScore {
        let hyp = hypothesis.sorted()
        let ref = reference.sorted()
        var matched = 0
        var i = 0
        var j = 0
        while i < hyp.count, j < ref.count {
            if abs(hyp[i] - ref[j]) <= tolerance {
                matched += 1
                i += 1
                j += 1
            } else if hyp[i] < ref[j] {
                i += 1
            } else {
                j += 1
            }
        }
        return BoundaryScore(
            matched: matched, hypothesisCount: hyp.count, referenceCount: ref.count)
    }

    // 連続する表示更新の間で「一度見せた文字が書き換わった」量 (flicker)。
    // normalized erasure = erasedCharacters / 最終表示長、として呼び出し側で正規化する
    static func erasedCharacters(updates: [String]) -> Int {
        var total = 0
        for (previous, current) in zip(updates, updates.dropFirst()) {
            total += max(0, previous.count - commonPrefixLength(previous, current))
        }
        return total
    }

    static func commonPrefixLength(_ a: String, _ b: String) -> Int {
        zip(a, b).prefix { $0 == $1 }.count
    }
}
