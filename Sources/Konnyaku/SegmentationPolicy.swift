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

    // 「〜について/として」等の複合格助詞は「て」で終わるが名詞句の途中なので切らない
    static let compoundParticleSuffixes: [String] = [
        "について", "として", "において", "にとって", "によって",
        "に関して", "に対して", "をめぐって", "に向けて", "につれて",
    ]

    // 動詞の音便形に後続する接続助詞「て」の直前に現れうる文字 (使って/聞いて/して/食べて 等)。
    // 「駅で」「会議室で」のような体言 + 格助詞と区別するための近似
    static let teFormPrecedingCharacters: Set<Character> = [
        "っ", "い", "し", "え", "け", "せ", "べ", "め", "ね", "れ", "げ", "て",
    ]

    // 「〜たから/〜するから」の接続用法を「駅から」の格助詞用法と区別するための
    // 動詞終端文字 (終止形の u 段 + た/だ/い)
    static let verbFinalCharacters: Set<Character> = [
        "た", "だ", "い", "う", "く", "ぐ", "す", "つ", "ぬ", "ぶ", "む", "る",
    ]

    // 「〜ですが/〜ましたが」の接続用法を「画面が」の主格用法と区別するための直前パターン
    static let gaClausePrecedingSuffixes: [String] = ["です", "ます", "た", "だ", "ない"]

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
    // 語彙規則で「接続助詞」と「体言 + 格助詞」(駅から / 画面が / 会議室で) を近似分別する
    static func endsAtClauseBoundary(_ text: String) -> Bool {
        for compound in compoundParticleSuffixes where text.hasSuffix(compound) {
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
            // 並列の接続助詞「〜だし/〜ますし」。体言終端の「し」(帽子/菓子) と区別
            guard chars.count >= 2 else { return false }
            return verbFinalCharacters.contains(chars[chars.count - 2])
        case "が":
            let head = String(chars.dropLast())
            return gaClausePrecedingSuffixes.contains { head.hasSuffix($0) }
        case "ら":
            guard text.hasSuffix("から"), chars.count >= 3 else { return false }
            return verbFinalCharacters.contains(chars[chars.count - 3])
        default:
            return false
        }
    }
}
