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
        let generation = state.volatileGeneration
        state.appendFinalSource("認識結果")
        state.replaceFinalSource("認識結果", with: "補正結果", generation: generation)
        #expect(state.sourceLines.map(\.text) == ["補正結果"])

        // 次の確定文が流れても、対象行が保持中なら差し替える
        state.appendFinalSource("次の文")
        state.replaceFinalSource("補正結果", with: "遅延補正", generation: generation)
        #expect(state.sourceLines.map(\.text) == ["遅延補正", "次の文"])

        // 対象行が既に押し出されて不在なら何もしない
        state.replaceFinalSource("押し出された文", with: "無関係な補正", generation: 999)
        #expect(state.sourceLines.map(\.text) == ["遅延補正", "次の文"])
    }

    // generation 一致で対象行を特定するため、backlog skip 等で補正の完了順序が入れ替わっても
    // 正しい行だけが差し替わる (文字列一致のみだと最古の一致行を誤って差し替える regression の防止)
    @Test
    func replaceFinalSourceTargetsMatchingGenerationAmongDuplicateText() {
        let state = CaptionState()
        let firstGeneration = state.volatileGeneration
        state.appendFinalSource("はい")
        let secondGeneration = state.volatileGeneration
        state.appendFinalSource("はい")

        // 後に確定した行 (secondGeneration) を先に補正しても、generation が
        // 一致する行だけが差し替わる (FIFO 前提の最古一致にはならない)
        state.replaceFinalSource("はい", with: "はい!", generation: secondGeneration)
        #expect(state.sourceLines.map(\.text) == ["はい", "はい!"])

        state.replaceFinalSource("はい", with: "はい。", generation: firstGeneration)
        #expect(state.sourceLines.map(\.text) == ["はい。", "はい!"])
    }

    // 遅延補正の差し替え直後に失効して補正が見えないまま消えるのを防ぐ
    @Test
    func replaceFinalSourceRefreshesLifetime() {
        let state = CaptionState()
        let base = Date(timeIntervalSinceReferenceDate: 0)
        let generation = state.volatileGeneration
        state.appendFinalSource("認識結果", at: base)
        state.replaceFinalSource("認識結果", with: "補正結果", generation: generation, at: base.addingTimeInterval(9))

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
    // (確定〜確定訳到着の間に下段が一瞬空になる regression の防止)。
    // 次の文の追従訳が先に届いた場合はそちらが優先して上書きする (追従スロットは 1 つ)。
    // 10 秒無更新なら pruneExpired が先に消す (確定訳到着までの無期限保証ではない)
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

    // 確定済みの前の文の placeholder (確定訳待ち) は、句読点のみ final の破棄では消さない
    // (確定訳は届くため、消すと到着まで下段が空く)
    @Test
    func discardVolatileSegmentKeepsPreviousSentencePlaceholder() {
        let state = CaptionState()
        let generationA = state.volatileGeneration
        state.setVolatileTranslation("A typing...", generation: generationA)
        state.appendFinalSource("文A")

        state.discardVolatileSegment()
        #expect(state.translationDisplayLines == ["A typing..."])

        state.appendTranslation("A final.", generation: generationA)
        #expect(state.translationDisplayLines == ["A final."])
    }

    // 前の文の確定訳が buffer 溢れで欠落したまま後の文の確定訳が届いた場合、前の文の
    // placeholder は孤児として消す (確定訳は文順に届くため、後の文の確定訳の到着は
    // それ以前の文の確定訳がもう来ないことを意味する)
    @Test
    func laterFinalTranslationClearsOrphanedOlderPlaceholder() {
        let state = CaptionState()
        let generationA = state.volatileGeneration
        state.setVolatileTranslation("A typing...", generation: generationA)
        state.appendFinalSource("文A")
        state.appendFinalSource("文B")

        state.appendTranslation("B final.", generation: generationA + 1)
        #expect(state.translationDisplayLines == ["B final."])
    }

    // stop 時は確定訳がもう届かないため、旧世代の placeholder も含め全て消す
    // (discardVolatileSegment の条件付きクリアへ統合すると stop 後の残留が再発する)
    @Test
    func clearVolatileRemovesEvenPreviousSentencePlaceholder() {
        let state = CaptionState()
        let generationA = state.volatileGeneration
        state.setVolatileTranslation("A typing...", generation: generationA)
        state.appendFinalSource("文A")

        state.clearVolatile()
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
