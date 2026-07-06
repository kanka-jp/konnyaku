import Foundation

// 言語・表示・AI 補正の設定を ~/.config/konnyaku/config (XDG_CONFIG_HOME 尊重) の
// key = value プレーンテキストで管理する。手編集の反映は次回起動時
enum ConfigStore {
    static let inputLanguageKey = "input-language"
    static let outputLanguageKey = "output-language"
    static let fontScaleKey = "font-scale"
    static let subtitlePlacementKey = "subtitle-placement"
    static let subtitlePositionKey = "subtitle-position"
    static let hideOverlayDuringShareKey = "hide-overlay-during-share"
    static let lowLatencyKey = "low-latency-translation"
    static let realtimeTranslationKey = "realtime-translation"
    static let correctionKey = "correction"
    static let autoStartKey = "auto-start"

    static var directoryURL: URL {
        let env = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        // XDG Base Directory 仕様: 相対パスの XDG_CONFIG_HOME は無効として無視する
        let base: URL
        if let env, env.hasPrefix("/") {
            base = URL(fileURLWithPath: env, isDirectory: true)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config", isDirectory: true)
        }
        return base.appendingPathComponent("konnyaku", isDirectory: true)
    }

    static var fileURL: URL {
        directoryURL.appendingPathComponent("config")
    }

    static let template = """
    # Konnyaku 設定 (書式: key = value、「#」で始まる行はコメント)
    # 設定画面からの変更もこのファイルへ書き戻されます。手編集は次回起動時に反映されます

    # 入力言語 (音声認識) の BCP-47 識別子
    input-language = ja-JP

    # 出力言語 (翻訳先) の識別子
    output-language = en-US

    # 字幕の文字サイズ: 0.5 〜 2.0 (0.1 刻み、既定 1.0)
    font-scale = 1.0

    # 共有ビューの字幕配置: overlay (映像に重ねる) / band (映像の外の黒帯に表示して映像と重ねない)
    subtitle-placement = overlay

    # 共有ビューの字幕の表示位置: bottom (下) / top (上)
    subtitle-position = bottom

    # 共有ビュー表示中は画面全体のオーバーレイ字幕を隠す (共有ビュー側と二重に見えるのを防ぐ): true / false
    hide-overlay-during-share = false

    # 低遅延翻訳 (lowLatency strategy、対応言語ペアのみ) を優先する: true / false
    low-latency-translation = true

    # 話し中テキストのリアルタイム翻訳 (false なら文の確定を待って翻訳): true / false
    realtime-translation = true

    # AI 補正 (Apple Intelligence による書き起こし校正、日本語入力のみ): true / false
    correction = false

    # アプリ起動時に字幕を自動で開始する: true / false
    auto-start = true
    """

    static func load() -> [String: String] {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return [:]
        }
        return parse(content)
    }

    static func parse(_ content: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in content.split(whereSeparator: \.isNewline) {
            guard let entry = parseEntry(line) else { continue }
            values[entry.key] = entry.value
        }
        return values
    }

    static func ensureFileExists() throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try (template + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    static func set(_ value: String, forKey key: String) {
        do {
            try ensureFileExists()
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            try updating(content, key: key, value: value)
                .write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            // 保存失敗は表示中の字幕動作に影響しない (次回起動時に既定値へ戻るだけ) ため握り潰す
        }
    }

    // 手編集のコメント・空行を壊さないため key の行だけを置換する (重複行は先頭に集約、無ければ末尾へ追記)
    static func updating(_ content: String, key: String, value: String) -> String {
        var lines: [String] = []
        var replaced = false
        for line in content.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if parseEntry(line)?.key == key {
                if !replaced {
                    lines.append("\(key) = \(value)")
                    replaced = true
                }
            } else {
                lines.append(String(line))
            }
        }
        if !replaced {
            while lines.last?.isEmpty == true {
                lines.removeLast()
            }
            lines.append("\(key) = \(value)")
        }
        var text = lines.joined(separator: "\n")
        if !text.hasSuffix("\n") {
            text += "\n"
        }
        return text
    }

    private static func parseEntry(_ line: Substring) -> (key: String, value: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
            return nil
        }
        guard let separator = trimmed.firstIndex(of: "=") else {
            return nil
        }
        let key = trimmed[..<separator].trimmingCharacters(in: .whitespaces)
        let value = trimmed[trimmed.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else {
            return nil
        }
        return (key, value)
    }
}
