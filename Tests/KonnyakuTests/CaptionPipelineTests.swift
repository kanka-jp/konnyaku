import Foundation
import Testing

@testable import Konnyaku

struct CaptionPipelineTests {
    // stop 後は pruneTask が止まり確定行が時間失効しないため、stop 自身が確定行を消す
    // 契約を固定する (消さないと停止後の位置調整で前回字幕がプレビューを塞ぐ)
    @Test
    @MainActor
    func stopClearsFinalLinesForStoppedAdjustmentPreview() async {
        let state = CaptionState()
        state.appendFinalSource("hello")
        state.appendTranslation("こんにちは", generation: 0)
        let pipeline = CaptionPipeline(state: state) {}

        await pipeline.stop()

        #expect(state.sourceDisplayLines.isEmpty)
        #expect(state.translationDisplayLines.isEmpty)
    }

    // OFF→ON→OFF 高速切替再現: 2回目の OFF で pendingCorrection が既に nil でも保留中の
    // 再起動要求は必ずクリアされる (regression: 旧実装は有無だけで判定し取りこぼしていた)
    @Test
    func resolveCorrectionToggleActionStopsAndClearsPendingRegardlessOfPendingCorrectionState() {
        #expect(CaptionPipeline.resolveCorrectionToggleAction(
            shouldRun: false, hasPendingCorrection: false, hasActiveCorrectionTask: true
        ) == .stopAndClearPending)
        #expect(CaptionPipeline.resolveCorrectionToggleAction(
            shouldRun: false, hasPendingCorrection: true, hasActiveCorrectionTask: true
        ) == .stopAndClearPending)
    }

    @Test
    func resolveCorrectionToggleActionDefersRestartWhenTaskStillDraining() {
        #expect(CaptionPipeline.resolveCorrectionToggleAction(
            shouldRun: true, hasPendingCorrection: false, hasActiveCorrectionTask: true
        ) == .deferRestart)
    }

    @Test
    func resolveCorrectionToggleActionStartsImmediatelyWhenIdle() {
        #expect(CaptionPipeline.resolveCorrectionToggleAction(
            shouldRun: true, hasPendingCorrection: false, hasActiveCorrectionTask: false
        ) == .startNow)
    }

    @Test
    func resolveCorrectionToggleActionNoopsWhenAlreadyRunning() {
        #expect(CaptionPipeline.resolveCorrectionToggleAction(
            shouldRun: true, hasPendingCorrection: true, hasActiveCorrectionTask: false
        ) == .noop)
    }

    // notInstalled 等で確定訳 worker が終了済み (translationTask == nil) の場合、部分更新は
    // 無視される。呼び出し元 (AppController) がこの false を見てフル再起動へフォールバックする
    @Test
    @MainActor
    func updateVolatileTranslationEnabledReturnsFalseWhenTranslationWorkerIsNotRunning() {
        let pipeline = CaptionPipeline(state: CaptionState()) {}
        let handled = pipeline.updateVolatileTranslationEnabled(
            true,
            inputLanguage: Locale.Language(identifier: "en"),
            outputLanguage: Locale.Language(identifier: "ja"),
            lowLatency: false
        )
        #expect(!handled)
    }

    @Test
    func resolveFinalTextRouteGoesToCorrectionWhenPendingCorrectionExists() {
        #expect(CaptionPipeline.resolveFinalTextRoute(
            hasPendingCorrection: true, hasDrainingCorrectionTask: true
        ) == .correction)
    }

    // drain 中は直接流すと旧 worker の補正結果を追い越すため、restart 予約の有無に関わらず
    // バッファへ retain する (regression: 旧実装は OFF 確定時のみ直行させ順序が入れ替わっていた)
    @Test
    func resolveFinalTextRouteBuffersWhileCorrectionTaskIsDraining() {
        #expect(CaptionPipeline.resolveFinalTextRoute(
            hasPendingCorrection: false, hasDrainingCorrectionTask: true
        ) == .bufferUntilDrainCompletes)
    }

    @Test
    func resolveFinalTextRouteGoesDirectWhenNoCorrectionPending() {
        #expect(CaptionPipeline.resolveFinalTextRoute(
            hasPendingCorrection: false, hasDrainingCorrectionTask: false
        ) == .direct)
    }
}
