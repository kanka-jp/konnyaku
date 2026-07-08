import Foundation

// 表示層の共通ヘルパー。純関数のみ (テストと eval が同一実装を共有する)
enum DisplayFormatting {
    // 追従訳末尾の書き換えを画面から隠す (Google の mask-k)。CJK 文字を含めば
    // 末尾 k 文字、含まなければ空白で区切った末尾 k トークンを切り落とす。
    // k <= 0 は元テキストを返す
    static func maskVolatileTail(text: String, k: Int) -> String {
        guard k > 0, !text.isEmpty else { return text }
        if containsCJK(text) {
            return maskCJKTail(text: text, k: k)
        }
        return maskWordTail(text: text, k: k)
    }

    // 元テキストと mask 適用後の長さの差 (eval の表示遅延メトリクス)
    static func maskedTailLength(text: String, k: Int) -> Int {
        text.count - maskVolatileTail(text: text, k: k).count
    }

    // CJK 文字が 1 つでも含まれるか (mixed-script 対策)。"OpenAIについて" の
    // ような Latin 過半 + CJK 混じりを word-based で扱うと空白なし CJK でトークン
    // 数 1 として全消去されるため、CJK 混在は保守的に char-based へ落とす
    private static func containsCJK(_ text: String) -> Bool {
        for character in text {
            if character.unicodeScalars.contains(where: isCJK) { return true }
        }
        return false
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.isIdeographic { return true }
        // Hiragana / Katakana (Unicode.Scalar.Properties は script 判定を持たないため
        // 主要ブロックを列挙する。フル文字体系より狭い代わりに script alias に依存しない)
        switch scalar.value {
        case 0x3040...0x309F, 0x30A0...0x30FF, 0x31F0...0x31FF: return true  // Hiragana / Katakana / Katakana Ext
        case 0xFF66...0xFF9F: return true  // Halfwidth Katakana
        case 0xAC00...0xD7A3: return true  // Hangul Syllables
        default: return false
        }
    }

    private static func maskCJKTail(text: String, k: Int) -> String {
        let chars = Array(text)
        guard chars.count > k else { return "" }
        return String(chars.prefix(chars.count - k))
    }

    // 空白 (Unicode whitespace) 区切りで末尾 k トークンを除去。トークン直後の
    // 空白も一緒に切り落とす (末尾スペースが残らないよう)
    private static func maskWordTail(text: String, k: Int) -> String {
        let chars = Array(text)
        var tokenTails: [Int] = []  // 各トークンの末尾 index の直後 (排他端)
        var inToken = false
        for (i, char) in chars.enumerated() {
            let isSpace = char.unicodeScalars.allSatisfy { $0.properties.isWhitespace }
            if isSpace {
                if inToken {
                    tokenTails.append(i)
                    inToken = false
                }
            } else {
                inToken = true
            }
        }
        if inToken { tokenTails.append(chars.count) }
        guard tokenTails.count > k else { return "" }
        // 残すのは末尾 k 個を除いた最後のトークン末尾まで (直後の空白は残さない)
        let cutIndex = tokenTails[tokenTails.count - k - 1]
        return String(chars.prefix(cutIndex))
    }
}
