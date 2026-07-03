import Foundation
import FoundationModels

// 確定した書き起こしをオンデバイス LLM (Apple Intelligence) で整形する
// (Aqua Voice / Typeless 系の AI ディクテーション後処理と同じ発想)
@MainActor
final class CorrectionEngine {
    static var isAvailable: Bool {
        SystemLanguageModel.default.isAvailable
    }

    static var unavailableReasonKey: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.appleIntelligenceNotEnabled):
            return "correction.unavailable.intelligence_off"
        case .unavailable(.deviceNotEligible):
            return "correction.unavailable.device"
        case .unavailable(.modelNotReady):
            return "correction.unavailable.not_ready"
        case .unavailable:
            return "correction.unavailable.device"
        }
    }

    private let instructions: String
    private var session: LanguageModelSession
    // 3B 級のオンデバイスモデルは出力が揺れやすいため greedy で決定的にする
    private let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: 256)

    init(languageName: String, vocabulary: [String] = []) {
        var vocabularySection = ""
        if !vocabulary.isEmpty {
            vocabularySection = """

            Domain terms (if a similar-sounding word appears, correct it to this exact form):
            \(vocabulary.joined(separator: ", "))
            """
        }
        // few-shot は小型モデルの指示追従に必須 (ゼロショットでは入力をほぼ echo する挙動を実測)。
        // 語尾・文体の保持は規則で書いてもモデルが無視することを実測済みのため、
        // プロンプトでは扱わず restoringSentenceEnding の決定論 post-guard で復元する
        instructions = """
        You are a post-processor for automatic speech recognition output in \(languageName). \
        Rewrite the input into clean subtitle text by applying ALL of these rules:
        - Fix homophone misrecognitions that are clearly wrong in context
        - Remove filler words (えっと, あの, まあ, ええと, なんか, ですね used as filler)
        - When the speaker corrects themselves (e.g. 「A、じゃなくてB」「A、違う、B」), keep only the correction B
        - Add natural punctuation
        - Never add new information, summarize, or paraphrase
        - If the input is already clean, output it unchanged
        Output ONLY the processed text with no explanations.\(vocabularySection)

        Examples:
        Input: えっと、機能の会議で決まった内容を、あの、共有します
        Output: 昨日の会議で決まった内容を共有します。
        Input: 速度を上げると制度が下がる問題を直した
        Output: 速度を上げると精度が下がる問題を直した。
        Input: リリースは明日、じゃなくて明後日にします
        Output: リリースは明後日にします。
        Input: 会議で製品の課題を共有した
        Output: 会議で製品の課題を共有した。
        """
        session = LanguageModelSession(instructions: instructions)
        session.prewarm()
    }

    // 現 session の会話履歴に残っている (原文 → モデル出力) 交換。echo 源は直近
    // 1 件でなく履歴全体のため、session と同期して蓄積し再作成時に空にする
    private var sessionExchanges: [(raw: String, result: String)] = []

    // session は失敗・汚染 (履歴 echo / 捏造長文) 検出時のみ作り直す。会話履歴の蓄積は guardrail 誤発火や
    // echo の一因になる (新 session 再試行で回復) 一方、履歴の (原文→補正) ペアが追加
    // few-shot として機能するため、毎回使い捨てると補正出力が崩壊することを eval で実測済み。
    // permissive guardrails も拒否を消す代わりに echo 化するため使わない (eval で実測)
    func correct(_ text: String) async -> String {
        if let corrected = await attempt(text) {
            // 履歴汚染で過去の回答をそのまま返すことがある (別の文が同文 2 行に
            // 化ける実害を観測)。echo は session 履歴 = 語尾復元前の出力の再出現
            // なので、復元前のモデル出力層で比較する (復元後比較では復元で変形した
            // 過去出力の echo を取りこぼす)。汚染検出時は履歴を捨てて再試行に落とす
            if !Self.isEchoOfSessionHistory(corrected, raw: text, history: sessionExchanges),
                !Self.isImplausiblyLong(corrected, comparedTo: text) {
                sessionExchanges.append((text, corrected))
                return Self.restoringSentenceEnding(of: corrected, toMatch: text)
            }
            debugLog(
                "correction contaminated (echo or implausible length \(text.count)→\(corrected.count)), retrying with fresh session"
            )
        }
        // 停止由来の失敗まで新 session の推論でリトライしない
        guard !Task.isCancelled else { return text }
        session = LanguageModelSession(instructions: instructions)
        sessionExchanges = []
        if let corrected = await attempt(text) {
            // 履歴を持たない fresh session に履歴 echo は起きないため再チェックしない
            // (過去と同じ補正結果になるのは別入力が同一補正に収束する正当ケース)。
            // 捏造長文は fresh session でも起きるため長さガードだけは再適用する
            if !Self.isImplausiblyLong(corrected, comparedTo: text) {
                sessionExchanges.append((text, corrected))
                return Self.restoringSentenceEnding(of: corrected, toMatch: text)
            }
            debugLog(
                "correction contaminated (implausible length \(text.count)→\(corrected.count) from fresh session), falling back to raw"
            )
        }
        // 失敗・汚染した session を次の文へ持ち越さない
        session = LanguageModelSession(instructions: instructions)
        sessionExchanges = []
        return text
    }

    // 「入力が違うのに履歴中のいずれかの出力と同一」は履歴 echo とみなす。
    // 同一 raw の言い直しが同じ補正に落ちるのは正当なため除外する。正当な補正が
    // 偶然過去の出力に収束するケースも echo 判定されるが、fresh session の
    // 再試行 (履歴なし = echo 不能) で採用されるため取りこぼさない
    static func isEchoOfSessionHistory(
        _ result: String,
        raw: String,
        history: [(raw: String, result: String)]
    ) -> Bool {
        history.contains { $0.result == result && $0.raw != raw }
    }

    // 正当な補正は filler 除去 (短縮)・同音異義語修正 (同長)・句読点付与 (数文字増) のみで、
    // それを大きく超える伸長は小型モデルの捏造 (9 文字入力 → 379 文字出力の実害を観測)。
    // 定数項はごく短い入力 (「はい」等) への句読点付与を誤検出しないための下駄
    static func isImplausiblyLong(_ result: String, comparedTo raw: String) -> Bool {
        result.count > raw.count * 2 + 12
    }

    // 話者の文体 (常体) を保つため、原文が常体で終わるのにモデル出力が対応する
    // 丁寧形へ変わっていた場合のみ語尾を復元する (プロンプト規則では抑止できないことを実測)
    private static let politenessDriftPairs: [(polite: String, plain: String)] = [
        ("しました", "した"),
        ("します", "する"),
        ("ています", "ている"),
        ("でした", "だった"),
        ("です", "だ"),
    ]

    static func restoringSentenceEnding(of corrected: String, toMatch raw: String) -> String {
        let isBodyCharacter: (Character) -> Bool = { !$0.isPunctuation && !$0.isWhitespace }
        guard let correctedBodyEnd = corrected.lastIndex(where: isBodyCharacter),
            let rawBodyEnd = raw.lastIndex(where: isBodyCharacter)
        else {
            return corrected
        }
        let correctedBody = corrected[...correctedBodyEnd]
        let rawBody = raw[...rawBodyEnd]
        let trailingPunctuation = corrected[corrected.index(after: correctedBodyEnd)...]
        for pair in politenessDriftPairs
        where rawBody.hasSuffix(pair.plain)
            && !rawBody.hasSuffix(pair.polite)
            && correctedBody.hasSuffix(pair.polite) {
            return String(correctedBody.dropLast(pair.polite.count)) + pair.plain + trailingPunctuation
        }
        return corrected
    }

    private func attempt(_ text: String) async -> String? {
        do {
            let corrected = try await session.respond(to: text, options: options).content
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return corrected.isEmpty ? nil : corrected
        } catch {
            debugLog("correction error: \(error)")
            return nil
        }
    }
}
