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
