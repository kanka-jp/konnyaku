import Foundation
import Testing

@testable import Konnyaku

struct SubtitleViewTests {
    // プレビューの段数が実表示と一致する契約 (翻訳無効なら source 1 段のみ)。
    // isTranslationEnabled ゲートが消えると調整時だけ 2 段になり位置合わせがずれる
    @Test
    @MainActor
    func previewOmitsTranslationRowWhenTranslationDisabled() {
        let settings = OverlaySettings(config: [:])
        settings.isMovable = true
        let languages = LanguageSettings(config: [
            ConfigStore.inputLanguageKey: "ja-JP",
            ConfigStore.outputLanguageKey: "ja-JP",
        ])
        let view = SubtitleView(state: CaptionState(), settings: settings, languages: languages, onFinishMoving: {})

        #expect(view.showsPreview)
        #expect(!view.sourceLines.isEmpty)
        #expect(view.translationLines.isEmpty)
    }

    @Test
    @MainActor
    func previewShowsTranslationRowWhenTranslationEnabled() {
        let settings = OverlaySettings(config: [:])
        settings.isMovable = true
        let languages = LanguageSettings(config: [
            ConfigStore.inputLanguageKey: "ja-JP",
            ConfigStore.outputLanguageKey: "en-US",
        ])
        let view = SubtitleView(state: CaptionState(), settings: settings, languages: languages, onFinishMoving: {})

        #expect(view.showsPreview)
        #expect(!view.translationLines.isEmpty)
    }

    // ロールアップの発火境界契約。追加分が表示高に収まる通常の行追加 (delta <=
    // container 高) で発火すると既存の即時表示がアニメーションに変わる regression、
    // 発火時に delta 全量を返さないと文頭が見えないまま流れ込む regression を防ぐ
    @Test
    func revealScrollDistanceFiresOnlyWhenAddedContentExceedsContainer() {
        // 通常の 1 行追加 (収まる) は発火しない
        #expect(
            SubtitleView.revealScrollDistance(
                previousContentHeight: 100, contentHeight: 140, containerHeight: 160,
                alignsToTop: false, finalsChanged: true
            ) == nil)
        // ちょうど表示高ぶんの追加は bottom 寄せで文頭まで見えるため発火しない
        #expect(
            SubtitleView.revealScrollDistance(
                previousContentHeight: 100, contentHeight: 260, containerHeight: 160,
                alignsToTop: false, finalsChanged: true
            ) == nil)
        // 表示高を超える一括追加は追加分全量をスクロールする
        #expect(
            SubtitleView.revealScrollDistance(
                previousContentHeight: 100, contentHeight: 300, containerHeight: 160,
                alignsToTop: false, finalsChanged: true
            ) == 200)
        // 行の失効等で高さが減った場合は発火しない
        #expect(
            SubtitleView.revealScrollDistance(
                previousContentHeight: 300, contentHeight: 100, containerHeight: 160,
                alignsToTop: false, finalsChanged: true
            ) == nil)
        // レイアウト未確定 (表示高 0) では duration が発散するため発火しない
        #expect(
            SubtitleView.revealScrollDistance(
                previousContentHeight: 0, contentHeight: 300, containerHeight: 0,
                alignsToTop: false, finalsChanged: true
            ) == nil)
    }

    // 発火ゲートの契約。確定行が変わらない高さ変化 (リサイズ・fontScale 変更の折り返し、
    // volatile の漸増) で発火すると話し中・リサイズ中に誤スクロールする regression、
    // 上寄せで発火すると鏡像の行順反転により読み順が逆転する regression を防ぐ
    @Test
    func revealScrollDistanceRequiresFinalChangeAndBottomAlignment() {
        // 確定行の変化を伴わない高さ増加 (折り返し・volatile) は発火しない
        #expect(
            SubtitleView.revealScrollDistance(
                previousContentHeight: 100, contentHeight: 300, containerHeight: 160,
                alignsToTop: false, finalsChanged: false
            ) == nil)
        // 上寄せ (鏡像) は他条件が揃っても発火しない
        #expect(
            SubtitleView.revealScrollDistance(
                previousContentHeight: 100, contentHeight: 300, containerHeight: 160,
                alignsToTop: true, finalsChanged: true
            ) == nil)
    }

    // ゾーン→カーソル方向の対応契約。NSView は非 flipped (y=0 が下端) のため
    // maxY 側が視覚上の上端になる。座標系の取り違え (上下反転) は実機でしか気づけない
    // regression なので純粋関数側で固定する
    @Test
    func frameResizePositionMapsEdgesAndCornersInUnflippedCoordinates() {
        let bounds = NSRect(x: 0, y: 0, width: 600, height: 400)
        typealias Tracking = ResizeCursorTracking.TrackingView
        #expect(Tracking.frameResizePosition(at: NSPoint(x: 300, y: 396), in: bounds) == .top)
        #expect(Tracking.frameResizePosition(at: NSPoint(x: 300, y: 4), in: bounds) == .bottom)
        #expect(Tracking.frameResizePosition(at: NSPoint(x: 4, y: 200), in: bounds) == .left)
        #expect(Tracking.frameResizePosition(at: NSPoint(x: 596, y: 200), in: bounds) == .right)
        #expect(Tracking.frameResizePosition(at: NSPoint(x: 8, y: 392), in: bounds) == .topLeft)
        #expect(Tracking.frameResizePosition(at: NSPoint(x: 592, y: 392), in: bounds) == .topRight)
        #expect(Tracking.frameResizePosition(at: NSPoint(x: 8, y: 8), in: bounds) == .bottomLeft)
        #expect(Tracking.frameResizePosition(at: NSPoint(x: 592, y: 8), in: bounds) == .bottomRight)
    }

    // 辺・角以外 (パネル中央) でリサイズカーソルを出さない契約 (中央でカーソルが
    // 変わるとドラッグ移動の operability 誤認につながる)
    @Test
    func frameResizePositionReturnsNilAwayFromEdges() {
        let bounds = NSRect(x: 0, y: 0, width: 600, height: 400)
        typealias Tracking = ResizeCursorTracking.TrackingView
        #expect(Tracking.frameResizePosition(at: NSPoint(x: 300, y: 200), in: bounds) == nil)
        #expect(Tracking.frameResizePosition(at: NSPoint(x: 300, y: 30), in: bounds) == nil)
    }
}
