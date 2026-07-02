import Testing

@testable import Konnyaku

struct VocabularyStoreTests {
    @Test
    func parseSkipsCommentsBlanksAndDuplicates() {
        let content = """
        # コメント行
        SpeechAnalyzer

          Konnyaku
        SpeechAnalyzer
        \t
        ほんやくコンニャク
        """
        #expect(VocabularyStore.parse(content) == ["SpeechAnalyzer", "Konnyaku", "ほんやくコンニャク"])
    }

    @Test
    func parseCapsTermCountAtLimit() {
        let content = (1...150).map { "term\($0)" }.joined(separator: "\n")
        let terms = VocabularyStore.parse(content)
        #expect(terms.count == VocabularyStore.maxTerms)
        #expect(terms.first == "term1")
        #expect(terms.last == "term\(VocabularyStore.maxTerms)")
    }
}
