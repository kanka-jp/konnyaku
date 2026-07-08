import Foundation

// 表示層の共通ヘルパー。純関数のみ (テストと eval が同一実装を共有する)
enum DisplayFormatting {
    // 追従訳末尾の書き換えを画面から隠す (Google の mask-k)。CJK 主体は末尾 k 文字、
    // 非 CJK は空白で区切った末尾 k トークンを切り落とす。k <= 0 は元テキストを返す
    static func maskVolatileTail(text: String, k: Int) -> String {
        guard k > 0, !text.isEmpty else { return text }
        if isCJKDominant(text) {
            return maskCJKTail(text: text, k: k)
        }
        return maskWordTail(text: text, k: k)
    }

    // 元テキストと mask 適用後の長さの差 (eval の表示遅延メトリクス)
    static func maskedTailLength(text: String, k: Int) -> Int {
        text.count - maskVolatileTail(text: text, k: k).count
    }

    // 表意文字・かな・ハングルが非空白文字の過半数を占めるとき CJK 主体扱い
    // (少数の記号「」・ が混じっても判定が Latin 側に倒れないため)
    private static func isCJKDominant(_ text: String) -> Bool {
        var visible = 0
        var cjk = 0
        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace { continue }
            visible += 1
            if isCJK(scalar) { cjk += 1 }
        }
        guard visible > 0 else { return false }
        return cjk * 2 > visible
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
