import Foundation

// 音声認識の contextualStrings と AI 補正プロンプトの両方へ注入するカスタム語彙
// (専門用語・固有名詞) を Application Support 配下のプレーンテキストで管理する
enum VocabularyStore {
    // contextualStrings の phrase biasing が有効に効く実用上限 (これ以上は先頭を優先)
    static let maxTerms = 100

    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Konnyaku", isDirectory: true)
            .appendingPathComponent("vocabulary.txt")
    }

    static func load() -> [String] {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return []
        }
        return parse(content)
    }

    static func parse(_ content: String) -> [String] {
        let terms = content
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        var seen = Set<String>()
        var unique: [String] = []
        for term in terms where seen.insert(term).inserted {
            unique.append(term)
        }
        return Array(unique.prefix(maxTerms))
    }

    static func ensureFileExists() throws {
        let url = fileURL
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            let template = """
            # Konnyaku カスタム語彙 (1 行 1 語)
            # 音声認識で誤認識されやすい専門用語・製品名・固有名詞を書くと認識がバイアスされます
            # 「#」で始まる行はコメントとして無視されます
            """
            try (template + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
