import AVFoundation
import Foundation
import Speech
import Synchronization
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

    // collector (認識結果) と feed 側 (audio 供給) を跨ぐポーズ判定の共有状態。
    // 無音中は volatile が来ず collector 側に判定機会が無いため、feed 側が
    // 供給チャンクごとに最新 volatile とその audio 終端を読んで判定する。
    // force 要求の in-flight flag (production の forcedFinalizeInFlight 相当、
    // finalize 失敗時に解除する契約も揃える) も同じ Mutex に置き、final 到着の
    // 状態遷移 (volatile クリア + flag 解除) と acquire を原子化する — 別 lock
    // だと snapshot〜acquire の間に final が割り込み、終了済みセグメントへ
    // stale volatile ベースの二重 finalize を発行しうる
    private final class PauseTracker: Sendable {
        struct Snapshot {
            var lastAudioEnd: TimeInterval?
            var volatileText: String
            var revision: Int
            var forcedInFlight: Bool
        }

        private struct State {
            var lastAudioEnd: TimeInterval?
            var volatileText = ""
            var revision = 0
            var forcedInFlight = false
        }

        private let state = Mutex(State())

        func snapshot() -> Snapshot {
            state.withLock {
                Snapshot(
                    lastAudioEnd: $0.lastAudioEnd, volatileText: $0.volatileText,
                    revision: $0.revision, forcedInFlight: $0.forcedInFlight)
            }
        }

        // production の recognitionTask と同じく text guard の前に全結果の audio
        // 終端を観測する (句読点のみの non-final でも認識活動はあった = 無音でない)
        func recordAudioActivity(audioEnd: TimeInterval) {
            state.withLock {
                $0.lastAudioEnd = audioEnd
                $0.revision += 1
            }
        }

        func recordVolatile(text: String, audioEnd: TimeInterval) {
            state.withLock {
                $0.volatileText = text
                $0.lastAudioEnd = audioEnd
                $0.revision += 1
            }
        }

        func recordFinal(audioEnd: TimeInterval) {
            state.withLock {
                $0.volatileText = ""
                $0.lastAudioEnd = audioEnd
                $0.revision += 1
                $0.forcedInFlight = false
            }
        }

        // snapshot 時点から状態が変わっていない場合に限り in-flight を取得する
        // (final の割り込みは終了済みセグメントへの発行、新しい volatile / 観測値の
        // 割り込みは閉じたポーズ・古いテキストでの発行になるため、いずれも
        // snapshot が stale なら取得せず次の判定機会に委ねる)
        func tryAcquireForceFinalize(ifRevisionEquals expected: Int) -> Bool {
            state.withLock {
                guard $0.revision == expected, !$0.forcedInFlight else { return false }
                $0.forcedInFlight = true
                return true
            }
        }

        func releaseForceFinalize() {
            state.withLock { $0.forcedInFlight = false }
        }
    }

    struct FinalSegment {
        let text: String
        // force 要求 in-flight 中に到着した final を true とする帰属 heuristic。
        // SpeechAnalyzer は final の発生要因を返さないため、要求直後の自然 final を
        // forced と数えうる (全 policy 同条件のため相対比較は有効)
        let forced: Bool
        let audioStart: Double?
        let audioEnd: Double?
        // replay 開始からの wall-clock 到着時刻 (秒)。arrival - audioEnd = 確定遅延
        let wallClockArrival: Double?
    }

    struct ReplayResult {
        var finals: [FinalSegment] = []
        // final ごとに、その final 到着までに観測した volatile テキスト列 + 末尾に
        // 置き換わる final 自身 (erasure 計算用。final は最後の volatile 表示を置き換える
        // ため、確定時の仮説修正による書き換えも表示列の flicker に含める)
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
        let pauseTracker = PauseTracker()
        let fedSecondsBox = Mutex(0.0)
        let collector = Task {
            var result = ReplayResult()
            var currentVolatiles: [String] = []
            for try await item in transcriber.results {
                let wasForced = pauseTracker.snapshot().forcedInFlight
                let range = Self.audioRange(of: item.text)
                // 時間属性なし結果は供給時刻へ fallback (production の
                // lastResultAudioEnd 更新と対称。stale な前セグメント終端で
                // 見かけのポーズが膨らむのを防ぐ)
                let resultAudioEnd = range?.end ?? fedSecondsBox.withLock { $0 }
                // production と同じく text guard の前に全結果を観測する
                // (句読点のみの結果でも認識活動 = 無音でないことは伝える)
                if item.isFinal {
                    pauseTracker.recordFinal(audioEnd: resultAudioEnd)
                } else {
                    pauseTracker.recordAudioActivity(audioEnd: resultAudioEnd)
                }
                let text = String(item.text.characters)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard text.contains(where: { $0.isLetter || $0.isNumber }) else {
                    // 捨てた final でもセグメントは切り替わっている (production の
                    // discardVolatileSegment と対)。表示中の volatile が空に消える遷移も
                    // 可視の flicker のため、空文字終端の run として erasure に計上する
                    if item.isFinal {
                        if !currentVolatiles.isEmpty {
                            result.volatileRuns.append(currentVolatiles + [""])
                        }
                        currentVolatiles = []
                    }
                    continue
                }
                if item.isFinal {
                    let elapsed = (ContinuousClock.now - replayStart).components
                    let arrival = Double(elapsed.seconds) + Double(elapsed.attoseconds) * 1e-18
                    result.finals.append(FinalSegment(
                        text: text,
                        forced: wasForced,
                        audioStart: range?.start,
                        audioEnd: range?.end,
                        wallClockArrival: arrival
                    ))
                    result.volatileRuns.append(currentVolatiles + [text])
                    currentVolatiles = []
                } else {
                    pauseTracker.recordVolatile(text: text, audioEnd: resultAudioEnd)
                    // production は全 volatile を表示する (翻訳へ流す最小長 filter は
                    // erasure 計算側で適用する)
                    currentVolatiles.append(text)
                    let snap = pauseTracker.snapshot()
                    let context = SegmentationPolicy.Context(
                        lastResultAudioEnd: resultAudioEnd,
                        audioFedThrough: fedSecondsBox.withLock { $0 })
                    if !snap.forcedInFlight,
                        policy.shouldForceFinalize(
                            text: text, threshold: threshold, context: context),
                        pauseTracker.tryAcquireForceFinalize(ifRevisionEquals: snap.revision)
                    {
                        // プロダクション同様、結果ループを塞がないよう別 Task で要求し
                        // (この場で await すると final の消費が止まり deadlock する)、
                        // 失敗時は flag を解除する (解除しないと以降の強制確定が止まり、
                        // 次の自然 final が forced 誤計上される)
                        Task {
                            if (try? await analyzer.finalize(through: nil)) == nil {
                                pauseTracker.releaseForceFinalize()
                            }
                        }
                    }
                }
            }
            return result
        }

        try await EvalAudio.feed(
            url: audioURL, into: continuation, analyzerFormat: analyzerFormat,
            pacedRealtime: true,
            onChunkFed: { fedSeconds in
                fedSecondsBox.withLock { $0 = fedSeconds }
                // 無音中は volatile が来ず collector 側に判定機会が無いため、
                // ポーズ駆動の policy は供給チャンクごとにも判定する (current /
                // clauseAware はテキスト駆動で同一入力に冪等のため実質 no-op)
                let observation = pauseTracker.snapshot()
                guard !observation.volatileText.isEmpty, !observation.forcedInFlight else { return }
                let context = SegmentationPolicy.Context(
                    lastResultAudioEnd: observation.lastAudioEnd,
                    audioFedThrough: fedSeconds)
                if policy.shouldForceFinalize(
                    text: observation.volatileText, threshold: threshold, context: context),
                    pauseTracker.tryAcquireForceFinalize(ifRevisionEquals: observation.revision)
                {
                    // collector 側の要求と同じ契約 (失敗時に flag 解除)
                    Task {
                        if (try? await analyzer.finalize(through: nil)) == nil {
                            pauseTracker.releaseForceFinalize()
                        }
                    }
                }
            })
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
    // chrF を出せない時、原因が翻訳環境かハーネスのバグかを切り分ける。
    // 翻訳不可は評価対象の欠陥でなく環境条件のため、fail させず print で報告する
    // (main evaluator の欠測 degrade と整合し、非翻訳指標だけの運用でも eval が緑で通る)
    @Test(.enabled(if: evalEnabled))
    func translationSessionSmoke() async throws {
        let pair = await TranslationSupport.resolvePair(
            input: Locale.Language(identifier: "ja"),
            output: Locale.Language(identifier: "en"))
        let session = TranslationSupport.makeSession(
            source: pair.source, target: pair.target, lowLatency: false)
        do {
            try await session.prepareTranslation()
            let translated = try await session.translate("こんにちは、今日は良い天気です。").targetText
            print("translationSessionSmoke: \(translated)")
            #expect(!translated.isEmpty)
        } catch {
            print("translationSessionSmoke: translation unavailable in this environment: \(error)")
        }
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

                // ハーネス自壊検知のみ assert する (品質の絶対値 gate は置かない。
                // 0.30 は実測 baseline CER 0.01-0.13 の数倍で、モデル drift でなく
                // 配線破損 — 誤った音声・セグメント欠落等 — のみ捕捉する粗い上限)
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
        // key は k (0/1/2/3)。maskedTranslationErasedByK[0] は translationErasedChars と一致。
        // maskedTranslationDelayCharsByK は最後の volatile 訳が mask で隠していた
        // 末尾長 (final 到着で復元される分) の総和
        let maskedTranslationErasedByK: [Int: Int]?
        let maskedTranslationDelayCharsByK: [Int: Int]?
        let finalTexts: [String]
        let translatedTexts: [String]?
    }

    // mask-k sweep で回す k の候補。0 は baseline (無適用)、production の default は
    // eval 結果を見て CaptionState.volatileTailMaskK に反映する
    static let maskCandidates = [0, 1, 2, 3]

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
        var maskedErasedByK: [Int: Int]?
        var maskedDelayByK: [Int: Int]?
        if let session {
            do {
                var translations: [String] = []
                for segment in replay.finals {
                    translations.append(try await session.translate(segment.text).targetText)
                }

                // 追従訳の flicker: volatile 列を drop なしで逐次翻訳した表示列の erasure。
                // production が翻訳へ流す最小長未満の volatile を除き (run 末尾の final は
                // 長さ不問で翻訳されるため対象外)、連続重複は表示が変わらないため除外する。
                // 同じ dedup 済み翻訳列で mask-k sweep も同時に計算する (翻訳を k 回
                // 呼ばず 1 回で済ませる)
                var erased = 0
                var maskedErased = Dictionary(uniqueKeysWithValues: Self.maskCandidates.map { ($0, 0) })
                var maskedDelay = Dictionary(uniqueKeysWithValues: Self.maskCandidates.map { ($0, 0) })
                for run in replay.volatileRuns {
                    var deduped: [String] = []
                    for (index, text) in run.enumerated()
                    where (index == run.count - 1
                        || text.count >= CaptionPipeline.minVolatileTranslationLength)
                        && !text.isEmpty && text != deduped.last
                    {
                        deduped.append(text)
                    }
                    var translatedRun: [String] = []
                    for text in deduped {
                        translatedRun.append(try await session.translate(text).targetText)
                    }
                    // 破棄セグメント (空文字終端の run) は production の discardVolatileSegment
                    // が追従訳表示もクリアするため、訳側の erase-to-empty も終端 "" で計上する
                    if run.last == "" {
                        translatedRun.append("")
                    }
                    erased += EvalMetrics.erasedCharacters(updates: translatedRun)

                    // production は volatile のみ mask し final は unmask 表示するため、
                    // 末尾要素 (final) を mask せず erasure に流し、表示遅延は最後の
                    // volatile の mask 隠し長 (final 到着で復元される分) で数える。
                    // 破棄セグメント (run.last == "") は production の discardVolatileSegment
                    // で mask 隠し末尾が復元されず消えるだけなので delay 計上対象外
                    let lastIndex = translatedRun.indices.last
                    // dedup で final と volatile が collapse された (translatedRun が 1 要素)
                    // ケースは、その要素が両方の役割を担う (production は mask 表示 → final
                    // unmask 表示の遷移を経るため delay 対象)
                    let lastVolatile =
                        translatedRun.count == 1
                        ? (translatedRun.last ?? "")
                        : (translatedRun.dropLast().last ?? "")
                    let volatileWillBeRestored = run.last != ""
                    for k in Self.maskCandidates {
                        let maskedRun = translatedRun.enumerated().map { index, text -> String in
                            if let lastIndex, index == lastIndex { return text }
                            return DisplayFormatting.maskVolatileTail(text: text, k: k)
                        }
                        maskedErased[k, default: 0] += EvalMetrics.erasedCharacters(updates: maskedRun)
                        if volatileWillBeRestored {
                            maskedDelay[k, default: 0] += DisplayFormatting.maskedTailLength(
                                text: lastVolatile, k: k)
                        }
                    }
                }
                translatedTexts = translations
                chrF = EvalMetrics.chrF(
                    hypothesis: translations.joined(separator: " "),
                    reference: monologue.referenceJoined)
                translationErased = erased
                maskedErasedByK = maskedErased
                maskedDelayByK = maskedDelay
            } catch {
                // 長時間 run の途中で翻訳が一時失敗しても当該 record の翻訳系指標だけ欠測に
                // degrade し、収集済み records (printReport / writeJSON) を失わない
                print("translation failed mid-run (\(monologue.id) / \(policy)): \(error)")
                chrF = nil
                translatedTexts = nil
                translationErased = nil
                maskedErasedByK = nil
                maskedDelayByK = nil
            }
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
            maskedTranslationErasedByK: maskedErasedByK,
            maskedTranslationDelayCharsByK: maskedDelayByK,
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
        // mask-k sweep: policy を跨いだ全 record の合計。訳の flicker 抑制 (erased 減)
        // と表示遅延 (delay 増) の trade-off を可視化する
        print("----- mask-k sweep (全 record 合計、erased/delay chars) -----")
        for k in Self.maskCandidates {
            // 翻訳系メトリクスが nil の record を 0 として集計すると欠測が
            // "計算できた 0" に見えるため、有効な record のみ合算する
            let metrics = records.compactMap { record -> (erased: Int, delay: Int)? in
                guard let erased = record.maskedTranslationErasedByK?[k],
                    let delay = record.maskedTranslationDelayCharsByK?[k]
                else { return nil }
                return (erased, delay)
            }
            guard !metrics.isEmpty else {
                print("k=\(k): erased=- delay=- records=0/\(records.count)")
                continue
            }
            let erased = metrics.reduce(0) { $0 + $1.erased }
            let delay = metrics.reduce(0) { $0 + $1.delay }
            print(
                "k=\(k): erased=\(erased) delay=\(delay) "
                    + "records=\(metrics.count)/\(records.count)")
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
