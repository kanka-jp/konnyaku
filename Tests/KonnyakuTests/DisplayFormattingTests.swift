import Testing

@testable import Konnyaku

struct DisplayFormattingTests {
    @Test
    func maskZeroReturnsOriginal() {
        #expect(DisplayFormatting.maskVolatileTail(text: "Hello world", k: 0) == "Hello world")
        #expect(DisplayFormatting.maskVolatileTail(text: "こんにちは世界", k: 0) == "こんにちは世界")
    }

    @Test
    func maskNegativeReturnsOriginal() {
        #expect(DisplayFormatting.maskVolatileTail(text: "Hello world", k: -1) == "Hello world")
    }

    @Test
    func maskEmptyReturnsEmpty() {
        #expect(DisplayFormatting.maskVolatileTail(text: "", k: 3) == "")
    }

    @Test
    func maskTrimsTrailingEnglishWords() {
        #expect(
            DisplayFormatting.maskVolatileTail(text: "The quick brown fox", k: 1)
                == "The quick brown")
        #expect(
            DisplayFormatting.maskVolatileTail(text: "The quick brown fox", k: 2) == "The quick")
        #expect(DisplayFormatting.maskVolatileTail(text: "The quick brown fox", k: 3) == "The")
    }

    @Test
    func maskConsumesTrailingWhitespace() {
        // 単語末尾の空白は残さない (次の描画で単語が伸びるとき見た目がジャンプしない)
        #expect(DisplayFormatting.maskVolatileTail(text: "Hello world ", k: 1) == "Hello")
    }

    @Test
    func maskTreatsMultipleSpacesAsSingleBoundary() {
        // 連続空白は 1 つの境界として数える (トークン数を過大評価しない)
        #expect(
            DisplayFormatting.maskVolatileTail(text: "one  two   three", k: 1)
                == "one  two")
    }

    @Test
    func maskReturnsEmptyWhenAllWordsRemoved() {
        #expect(DisplayFormatting.maskVolatileTail(text: "one two", k: 2) == "")
        #expect(DisplayFormatting.maskVolatileTail(text: "one two three", k: 5) == "")
    }

    @Test
    func maskTrimsTrailingCJKCharacters() {
        #expect(DisplayFormatting.maskVolatileTail(text: "音声認識を試す", k: 1) == "音声認識を試")
        #expect(DisplayFormatting.maskVolatileTail(text: "音声認識を試す", k: 3) == "音声認識")
    }

    @Test
    func maskHandlesHiraganaKatakanaHangul() {
        #expect(DisplayFormatting.maskVolatileTail(text: "ひらがな", k: 1) == "ひらが")
        #expect(DisplayFormatting.maskVolatileTail(text: "カタカナ", k: 1) == "カタカ")
        #expect(DisplayFormatting.maskVolatileTail(text: "안녕하세요", k: 1) == "안녕하세")
    }

    @Test
    func maskCJKReturnsEmptyWhenAllCharactersRemoved() {
        #expect(DisplayFormatting.maskVolatileTail(text: "音声", k: 2) == "")
        #expect(DisplayFormatting.maskVolatileTail(text: "音声", k: 5) == "")
    }

    @Test
    func maskTreatsMixedCJKMajoritatedAsCharBased() {
        // 少数の記号・数字を含む CJK 文は文字単位で刈る (Latin 判定に倒れない)
        #expect(
            DisplayFormatting.maskVolatileTail(text: "会議は3件あります", k: 2)
                == "会議は3件あり")
    }

    @Test
    func maskTreatsMixedLatinMajoritatedAsWordBased() {
        // Latin 文字が過半なら単語単位 (少数 CJK が混じっても Latin 側に倒れる)
        #expect(
            DisplayFormatting.maskVolatileTail(text: "hello 世界 world", k: 1) == "hello 世界")
    }

    @Test
    func maskedTailLengthMatchesRemovedCharacters() {
        // 表示遅延メトリクスは元テキストと mask 済みテキストの差で数える
        #expect(
            DisplayFormatting.maskedTailLength(text: "The quick brown fox", k: 1) == 4)
        #expect(DisplayFormatting.maskedTailLength(text: "音声認識を試す", k: 2) == 2)
        #expect(DisplayFormatting.maskedTailLength(text: "Hello world ", k: 1) == 7)
    }
}
