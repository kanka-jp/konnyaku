import Foundation

// 強制確定 (段落を待たず文を区切る) の判定ポリシー。app と eval が同一実装を共有し、
// eval (SegmentationEvaluationTests) は複数 case を同一音声で A/B 比較する
enum SegmentationPolicy: CaseIterable, CustomStringConvertible {
    // 文字数閾値 + 末尾句読点 (末尾 10 字以内) + 1.5 倍ハードリミット
    case current
    // 文字数閾値 + 末尾アンカーの節境界判定 + 1.5 倍ハードリミット。
    // 「末尾付近の句読点」は句読点の後に語が続いた位置 (「…ので、表示を」) でも発火して
    // 語中分断を招くため、末尾そのものが区切りのときだけ確定する。
    // 日→英 (SOV→SVO) では動詞前の分断が訳を壊すため節境界で切る
    case clauseAware

    var description: String {
        switch self {
        case .current: return "current"
        case .clauseAware: return "clauseAware"
        }
    }

    // 閾値超過後も区切りが見つからない場合に強制確定を保留する上限 (閾値の倍数)
    static let graceMultiplier = 1.5
    // 句読点の有無を確認する対象は末尾付近のみ (先頭寄りの句読点で誤って早期確定しないため)
    static let punctuationTailWindow = 10
    static let sentenceBreakPunctuation: Set<Character> = [
        "、", "。", "，", "．", "！", "？", ",", ".", "!", "?",
    ]

    // 前後の品詞に依らず節境界とみなせる接続助詞・接続形の末尾。
    // 「ので/のに」は体言接続が「なので/なのに」になるため単独で接続用法に確定し、
    // 「けど/けれど(も)」「たら/れば/なら/ながら/つつ」も体言直結の用法が事実上ない
    static let unconditionalClauseSuffixes: [String] = [
        "ので", "のに", "けど", "けれど", "けれども",
        "たら", "だら", "れば", "なら", "ながら", "つつ",
    ]

    // 表層が接続助詞規則に一致しても節境界でない末尾の負条件 (肯定規則より先に評価する)。
    // 複合格助詞 (について 等) は「て」終端、ひらがな敬称 + で (みなさんで 等) は「ん + で」、
    // 程度表現 + から (くらいから 等) は「い + から」で、それぞれ肯定規則と衝突するが
    // いずれも体言句の途中のため切らない
    static let nonBoundarySuffixes: [String] = [
        "について", "として", "において", "にとって", "によって",
        "に関して", "に対して", "をめぐって", "に向けて", "につれて",
        "に基づいて", "に応じて", "に沿って", "にわたって", "に従って", "に加えて",
        "さんで", "ちゃんで", "くんで",
        "くらいから", "ぐらいから",
    ]

    // 接続助詞「て」の直前に現れうる文字。五段動詞の音便形 (使って/聞いて/読んで) と
    // かな語幹の一段動詞 (食べて/できて/信じて)。見て/出て/来て 等の漢字一文字語幹は
    // 直前が漢字になるため本方式では判定できない (既知の保留側トレードオフ)。
    // 「に」は「〜にて」(格助詞) と衝突するため含めない
    static let teFormPrecedingCharacters: Set<Character> = [
        "っ", "い", "し", "え", "け", "せ", "べ", "め", "ね", "れ", "げ", "て",
        "き", "ぎ", "じ", "ち", "み", "り", "び", "ひ",
    ]

    // 「〜たから/〜するから」の接続用法を「駅から」の格助詞用法と区別するための
    // 動詞終端文字 (終止形の u 段 + た/だ/い)
    static let verbFinalCharacters: Set<Character> = [
        "た", "だ", "い", "う", "く", "ぐ", "す", "つ", "ぬ", "ぶ", "む", "る",
    ]

    // 「〜ですが/〜ましたが/〜ませんが」の接続用法を「画面が」の主格用法と区別するための直前パターン
    static let gaClausePrecedingSuffixes: [String] = ["です", "ます", "ません", "た", "だ", "ない"]

    // 閾値超過後、区切りらしい位置なら確定要求する。無ければ閾値の 1.5 倍まで
    // 保留し Speech 側の自然な final 発火を待つ (純関数・テスト対象)
    func shouldForceFinalize(text: String, threshold: Int) -> Bool {
        let count = text.count
        guard count >= threshold else { return false }
        let hardLimit = Int(Double(threshold) * Self.graceMultiplier)
        if count >= hardLimit { return true }
        switch self {
        case .current:
            return text.suffix(Self.punctuationTailWindow)
                .contains { Self.sentenceBreakPunctuation.contains($0) }
        case .clauseAware:
            if let last = text.last, Self.sentenceBreakPunctuation.contains(last) {
                return true
            }
            return Self.endsAtClauseBoundary(text)
        }
    }

    // 末尾が接続助詞で終わる節境界かを表層形の規則で判定する。
    // NLTagger の .lexicalClass は日本語では全トークンに .otherWord を返し品詞判定に
    // 使えない (実測) ため、形態素の品詞ではなく末尾サフィックス + 直前文字の
    // 語彙規則で「接続助詞」と「体言 + 格助詞」(駅から / 画面が / 会議室で) を近似分別する。
    // 判定は ASR 出力の書字文字に対して行う (漢字正規化により体言の多くは
    // 漢字終端になり、かな終端を前提とする肯定規則と自然に分離される)
    static func endsAtClauseBoundary(_ text: String) -> Bool {
        for suffix in nonBoundarySuffixes where text.hasSuffix(suffix) {
            return false
        }
        for suffix in unconditionalClauseSuffixes where text.hasSuffix(suffix) {
            return true
        }
        let chars = Array(text)
        guard let last = chars.last else { return false }
        switch last {
        case "て":
            guard chars.count >= 2 else { return false }
            return teFormPrecedingCharacters.contains(chars[chars.count - 2])
        case "で":
            // 音便形「読んで/飲んで」のみ。他の「で」は格助詞が圧倒的に多い
            guard chars.count >= 2 else { return false }
            return chars[chars.count - 2] == "ん"
        case "し":
            // 並列の接続助詞「〜だし/〜ますし」。かな終端の体言 (むかし 等) と区別
            guard chars.count >= 2 else { return false }
            return verbFinalCharacters.contains(chars[chars.count - 2])
        case "が":
            let head = String(chars.dropLast())
            return gaClausePrecedingSuffixes.contains { head.hasSuffix($0) }
        case "ら":
            guard text.hasSuffix("から"), chars.count >= 3 else { return false }
            // 「確認してから/読んでから」の て形 + から も時間接続の節境界
            if text.hasSuffix("てから") || text.hasSuffix("でから") { return true }
            return verbFinalCharacters.contains(chars[chars.count - 3])
        default:
            return false
        }
    }
}
