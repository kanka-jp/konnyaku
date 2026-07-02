import Testing

@testable import Konnyaku

struct ConfigStoreTests {
    @Test
    func parseSkipsCommentsAndBlanksAndSplitsOnFirstEquals() {
        let content = """
        # コメント行
        input-language = ja-JP

          output-language=en-US
        key-only-line
        url = https://example.com/?a=b
        """
        #expect(ConfigStore.parse(content) == [
            "input-language": "ja-JP",
            "output-language": "en-US",
            "url": "https://example.com/?a=b",
        ])
    }

    @Test
    func parseLastValueWinsForDuplicateKeys() {
        let content = """
        font-scale = 0.8
        font-scale = 1.3
        """
        #expect(ConfigStore.parse(content) == ["font-scale": "1.3"])
    }

    @Test
    func updatingReplacesValuePreservingCommentsAndDroppingDuplicates() {
        let content = """
        # ヘッダコメント
        input-language = ja-JP

        font-scale = 0.8
        font-scale = 1.3
        """
        let updated = ConfigStore.updating(content, key: "font-scale", value: "1.0")
        #expect(updated == """
        # ヘッダコメント
        input-language = ja-JP

        font-scale = 1.0

        """)
    }

    @Test
    func updatingReplacesKeyInCRLFContentInsteadOfAppendingDuplicate() {
        let content = "# comment\r\ncorrection = false\r\n"
        let updated = ConfigStore.updating(content, key: "correction", value: "true")
        #expect(updated == "# comment\ncorrection = true\n")
    }

    @Test
    func updatingAppendsMissingKeyWithSingleTrailingNewline() {
        let content = "input-language = ja-JP\n\n"
        let updated = ConfigStore.updating(content, key: "correction", value: "true")
        #expect(updated == "input-language = ja-JP\ncorrection = true\n")
    }
}
