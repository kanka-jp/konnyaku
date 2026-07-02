import Foundation
import Testing

@testable import Konnyaku

@MainActor
struct CaptionStateTests {
    @Test
    func finalizedSourceClearsVolatileAndTrimsRetention() {
        let state = CaptionState()
        state.setVolatileSource("こんにち")
        state.appendFinalSource("こんにちは")
        #expect(state.volatileSource.isEmpty)

        state.appendFinalSource("二文目")
        state.appendFinalSource("三文目")
        state.appendFinalSource("四文目")
        #expect(state.sourceLines.map(\.text) == ["二文目", "三文目", "四文目"])
    }

    @Test
    func sourceDisplayStacksFinalizedAndVolatileAsLines() {
        let state = CaptionState()
        #expect(state.sourceDisplayLines.isEmpty)

        state.setVolatileSource("話し中")
        #expect(state.sourceDisplayLines == ["話し中"])

        state.appendFinalSource("確定文")
        #expect(state.sourceDisplayLines == ["確定文"])

        state.setVolatileSource("次の話し中")
        #expect(state.sourceDisplayLines == ["確定文", "次の話し中"])
    }

    @Test
    func replaceFinalSourceMatchesRetainedLineOnly() {
        let state = CaptionState()
        state.appendFinalSource("認識結果")
        state.replaceFinalSource("認識結果", with: "補正結果")
        #expect(state.sourceLines.map(\.text) == ["補正結果"])

        // 次の確定文が流れても、対象行が保持中なら差し替える
        state.appendFinalSource("次の文")
        state.replaceFinalSource("補正結果", with: "遅延補正")
        #expect(state.sourceLines.map(\.text) == ["遅延補正", "次の文"])

        // 対象行が既に押し出されて不在なら何もしない
        state.replaceFinalSource("押し出された文", with: "無関係な補正")
        #expect(state.sourceLines.map(\.text) == ["遅延補正", "次の文"])
    }

    // 補正 worker は FIFO のため、同一テキストの重複行では最古の一致行から差し替わる
    @Test
    func replaceFinalSourceTargetsOldestDuplicateFirst() {
        let state = CaptionState()
        state.appendFinalSource("はい")
        state.appendFinalSource("はい")
        state.replaceFinalSource("はい", with: "はい。")
        #expect(state.sourceLines.map(\.text) == ["はい。", "はい"])

        state.replaceFinalSource("はい", with: "はい!")
        #expect(state.sourceLines.map(\.text) == ["はい。", "はい!"])
    }

    // 遅延補正の差し替え直後に失効して補正が見えないまま消えるのを防ぐ
    @Test
    func replaceFinalSourceRefreshesLifetime() {
        let state = CaptionState()
        let base = Date(timeIntervalSinceReferenceDate: 0)
        state.appendFinalSource("認識結果", at: base)
        state.replaceFinalSource("認識結果", with: "補正結果", at: base.addingTimeInterval(9))

        state.pruneExpired(now: base.addingTimeInterval(CaptionState.lineLifetime + 1))
        #expect(state.sourceLines.map(\.text) == ["補正結果"])
    }

    @Test
    func translationRetentionAndDisplay() {
        let state = CaptionState()
        state.appendTranslation("First.", generation: 0)
        state.appendTranslation("Second.", generation: 1)
        state.appendTranslation("Third.", generation: 2)
        state.appendTranslation("Fourth.", generation: 3)
        #expect(state.translationDisplayLines == ["Second.", "Third.", "Fourth."])
    }

    @Test
    func pruneExpiredRemovesOnlyAgedLines() {
        let state = CaptionState()
        let base = Date(timeIntervalSinceReferenceDate: 0)
        state.appendFinalSource("古い文", at: base)
        state.appendFinalSource("新しい文", at: base.addingTimeInterval(8))
        state.appendTranslation("Old.", generation: 0, at: base)
        state.appendTranslation("New.", generation: 1, at: base.addingTimeInterval(8))

        state.pruneExpired(now: base.addingTimeInterval(CaptionState.lineLifetime + 1))
        #expect(state.sourceLines.map(\.text) == ["新しい文"])
        #expect(state.translationDisplayLines == ["New."])

        state.pruneExpired(now: base.addingTimeInterval(CaptionState.lineLifetime + 10))
        #expect(state.sourceLines.isEmpty)
        #expect(state.translationDisplayLines.isEmpty)
    }

    @Test
    func pruneExpiredClearsStaleVolatile() {
        let state = CaptionState()
        let base = Date(timeIntervalSinceReferenceDate: 0)
        state.setVolatileSource("話し中", at: base)

        state.pruneExpired(now: base.addingTimeInterval(CaptionState.lineLifetime - 1))
        #expect(state.volatileSource == "話し中")

        state.pruneExpired(now: base.addingTimeInterval(CaptionState.lineLifetime + 1))
        #expect(state.volatileSource.isEmpty)
    }

    // 話し中の追従訳は確定訳の後ろに 1 行表示され、自分の文の確定訳の到着で置き換わる
    @Test
    func volatileTranslationDisplaysAfterFinalizedAndIsReplacedByFinal() {
        let state = CaptionState()
        state.appendTranslation("First.", generation: 0)
        let generation = state.volatileGeneration
        state.setVolatileTranslation("typing...", generation: generation)
        #expect(state.translationDisplayLines == ["First.", "typing..."])

        // 文の確定 (世代が進む) 後に届いた同世代の確定訳が追従訳を置き換える
        state.appendFinalSource("確定文")
        state.appendTranslation("Second.", generation: generation)
        #expect(state.translationDisplayLines == ["First.", "Second."])
    }

    // 文確定の瞬間に追従訳を消さず、自分の確定訳の到着まで placeholder として残す
    // (確定〜確定訳到着の間に下段が一瞬空になる regression の防止)
    @Test
    func volatileTranslationPersistsAcrossFinalizeUntilRealTranslationArrives() {
        let state = CaptionState()
        let generation = state.volatileGeneration
        state.setVolatileTranslation("half sentence...", generation: generation)
        state.appendFinalSource("確定文")
        #expect(state.translationDisplayLines == ["half sentence..."])

        state.appendTranslation("Real translation.", generation: generation)
        #expect(state.translationDisplayLines == ["Real translation."])
    }

    // 前の文の確定訳が遅れて到着しても、既に表示中の次の文の追従訳は消さない
    // (追従表示が一瞬消える flicker の regression 防止)
    @Test
    func delayedFinalTranslationKeepsNextSentenceVolatileTranslation() {
        let state = CaptionState()
        // 文 A が確定して世代が進み、文 B の追従訳が表示されている
        let generationA = state.volatileGeneration
        state.appendFinalSource("文A")
        state.setVolatileTranslation("B typing...", generation: state.volatileGeneration)

        // 文 A の確定訳が遅れて到着
        state.appendTranslation("A final.", generation: generationA)
        #expect(state.translationDisplayLines == ["A final.", "B typing..."])
    }

    // 文 B の確定後に文 A の確定訳が届いても B の追従訳は残り、B 自身の確定訳で置き換わる
    // (世代差の有無ではなく「同世代か」で置き換え対象を判定する regression 防止)
    @Test
    func delayedFinalTranslationAfterNextSentenceFinalizedKeepsItsPlaceholder() {
        let state = CaptionState()
        let generationA = state.volatileGeneration
        state.appendFinalSource("文A")
        let generationB = state.volatileGeneration
        state.setVolatileTranslation("B typing...", generation: generationB)
        state.appendFinalSource("文B")

        state.appendTranslation("A final.", generation: generationA)
        #expect(state.translationDisplayLines == ["A final.", "B typing..."])

        state.appendTranslation("B final.", generation: generationB)
        #expect(state.translationDisplayLines == ["A final.", "B final."])
    }

    // 句読点のみ等で final を捨てたセグメントも世代が進み、話し中表示と追従訳が消え、
    // in-flight の追従訳も受理されない (確定訳が来ないため残すと 10 秒残骸になる)
    @Test
    func discardVolatileSegmentClearsVolatileAndRejectsInFlight() {
        let state = CaptionState()
        let generation = state.volatileGeneration
        state.setVolatileSource("話し中")
        state.setVolatileTranslation("typing...", generation: generation)

        state.discardVolatileSegment()
        #expect(state.sourceDisplayLines.isEmpty)
        #expect(state.translationDisplayLines.isEmpty)

        state.setVolatileTranslation("stale", generation: generation)
        #expect(state.translationDisplayLines.isEmpty)
    }

    // 訳している間に文が確定した (世代が進んだ) 追従訳は stale として捨てる。
    // 捨てないと確定訳の後に古い追従訳が再表示される
    @Test
    func volatileTranslationRejectsStaleGeneration() {
        let state = CaptionState()
        let generation = state.volatileGeneration
        state.appendFinalSource("確定文")
        state.setVolatileTranslation("stale", generation: generation)
        #expect(state.translationDisplayLines.isEmpty)

        state.setVolatileTranslation("fresh", generation: state.volatileGeneration)
        #expect(state.translationDisplayLines == ["fresh"])
    }

    @Test
    func pruneExpiredClearsStaleVolatileTranslation() {
        let state = CaptionState()
        let base = Date(timeIntervalSinceReferenceDate: 0)
        state.setVolatileTranslation("typing...", generation: state.volatileGeneration, at: base)

        state.pruneExpired(now: base.addingTimeInterval(CaptionState.lineLifetime - 1))
        #expect(state.translationDisplayLines == ["typing..."])

        state.pruneExpired(now: base.addingTimeInterval(CaptionState.lineLifetime + 1))
        #expect(state.translationDisplayLines.isEmpty)
    }

    @Test
    func resetClearsAllCaptionContent() {
        let state = CaptionState()
        state.setVolatileSource("話し中")
        state.appendFinalSource("確定文")
        state.appendTranslation("Translated.", generation: 0)
        state.setVolatileTranslation("typing...", generation: state.volatileGeneration)
        state.reset()
        #expect(state.sourceDisplayLines.isEmpty)
        #expect(state.translationDisplayLines.isEmpty)
    }
}
