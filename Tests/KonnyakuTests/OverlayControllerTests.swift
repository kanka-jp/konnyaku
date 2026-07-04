import Foundation
import Testing

@testable import Konnyaku

struct OverlayControllerTests {
    @Test
    func panelHeightScalesWithFontScaleAboveMinimumFloor() {
        let base = OverlayController.panelHeight(fontScale: 1.0, availableHeight: 2000, margin: 24)
        let doubled = OverlayController.panelHeight(fontScale: 2.0, availableHeight: 2000, margin: 24)
        let expected = base * 2
        #expect(doubled == expected)
    }

    @Test
    func panelHeightMatchesLegacyFixedHeightAtDefaultScale() {
        let height = OverlayController.panelHeight(fontScale: 1.0, availableHeight: 2000, margin: 24)
        let expected: CGFloat = 380
        #expect(height == expected)
    }

    @Test
    func panelHeightAppliesMinimumFloorAtSmallFontScale() {
        let height = OverlayController.panelHeight(fontScale: 0.5, availableHeight: 1000, margin: 24)
        let expected: CGFloat = 200
        #expect(height == expected)
    }

    @Test
    func panelHeightClampsToAvailableScreenHeight() {
        let height = OverlayController.panelHeight(fontScale: 2.0, availableHeight: 400, margin: 24)
        let expected: CGFloat = 352
        #expect(height == expected)
    }

    @Test
    func panelHeightAtMaxFontScaleFitsWithinTypicalScreen() {
        let availableHeight: CGFloat = 900
        let margin: CGFloat = 24
        let height = OverlayController.panelHeight(fontScale: 2.0, availableHeight: availableHeight, margin: margin)
        #expect(height > 380)
        #expect(height <= availableHeight - margin * 2)
    }

    @Test
    func clampedOriginKeepsInBoundsOriginUnchanged() {
        let screen = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let origin = OverlayController.clampedOrigin(
            origin: NSPoint(x: 24, y: 24), size: NSSize(width: 952, height: 380), screenFrame: screen
        )
        #expect(origin == NSPoint(x: 24, y: 24))
    }

    @Test
    func clampedOriginPullsBackWhenGrowingWouldExceedScreenTop() {
        let screen = NSRect(x: 0, y: 0, width: 1000, height: 900)
        let origin = OverlayController.clampedOrigin(
            origin: NSPoint(x: 24, y: 500), size: NSSize(width: 952, height: 760), screenFrame: screen
        )
        #expect(origin == NSPoint(x: 24, y: 140))
    }

    @Test
    func clampedOriginPullsBackHorizontalOverflowMinimally() {
        let screen = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let origin = OverlayController.clampedOrigin(
            origin: NSPoint(x: -10, y: 24), size: NSSize(width: 952, height: 380), screenFrame: screen
        )
        #expect(origin.x == 0)
    }

    @Test
    func resizedFramePreservesOriginWhenGrowthStaysOnScreen() {
        let current = NSRect(x: 24, y: 24, width: 952, height: 380)
        let screen = NSRect(x: 0, y: 0, width: 1000, height: 2000)
        let resized = OverlayController.resizedFrame(current: current, fontScale: 2.0, screenFrame: screen, margin: 24)
        #expect(resized.origin == current.origin)
        let expectedHeight = OverlayController.panelHeight(fontScale: 2.0, availableHeight: 2000, margin: 24)
        #expect(resized.height == expectedHeight)
    }

    @Test
    func resizedFrameClampsHeightToAvailableScreenHeight() {
        let current = NSRect(x: 24, y: 24, width: 952, height: 380)
        let screen = NSRect(x: 0, y: 0, width: 1000, height: 400)
        let resized = OverlayController.resizedFrame(current: current, fontScale: 2.0, screenFrame: screen, margin: 24)
        let expected: CGFloat = 352
        #expect(resized.height == expected)
    }

    @Test
    func resizedFramePullsOriginBackWhenGrowthWouldExceedScreenTop() {
        let current = NSRect(x: 24, y: 500, width: 952, height: 380)
        let screen = NSRect(x: 0, y: 0, width: 1000, height: 900)
        let resized = OverlayController.resizedFrame(current: current, fontScale: 2.0, screenFrame: screen, margin: 24)
        #expect(resized.origin.y + resized.height <= screen.maxY)
    }

    @Test
    func resolvedShowFrameUsesMainScreenDefaultWhenNoSavedOrigin() {
        let main = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let frame = OverlayController.resolvedShowFrame(
            fontScale: 1.0, savedOrigin: nil, screenFrames: [main], mainScreenFrame: main, margin: 24
        )
        #expect(frame == NSRect(x: 24, y: 24, width: 952, height: 380))
    }

    @Test
    func resolvedShowFrameFallsBackToMainDefaultWhenOriginAndFrameMatchNoScreen() {
        let main = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let frame = OverlayController.resolvedShowFrame(
            fontScale: 1.0, savedOrigin: NSPoint(x: 5000, y: 5000), screenFrames: [main], mainScreenFrame: main, margin: 24
        )
        #expect(frame.origin == NSPoint(x: 24, y: 24))
    }

    @Test
    func resolvedShowFrameClampsLargeHorizontalDragInsteadOfResettingToDefault() {
        let main = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let frame = OverlayController.resolvedShowFrame(
            fontScale: 1.0, savedOrigin: NSPoint(x: 100, y: 24), screenFrames: [main], mainScreenFrame: main, margin: 24
        )
        #expect(frame.origin == NSPoint(x: 48, y: 24))
    }

    @Test
    func resolvedShowFrameClampsLeftwardDragInsteadOfResettingToDefault() {
        let main = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let frame = OverlayController.resolvedShowFrame(
            fontScale: 1.0, savedOrigin: NSPoint(x: -10, y: 24), screenFrames: [main], mainScreenFrame: main, margin: 24
        )
        #expect(frame.origin == NSPoint(x: 0, y: 24))
    }

    @Test
    func resolvedShowFrameSizesForScreenContainingSavedOrigin() {
        let main = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let secondary = NSRect(x: 1000, y: 0, width: 600, height: 400)
        let frame = OverlayController.resolvedShowFrame(
            fontScale: 2.0, savedOrigin: NSPoint(x: 1200, y: 100), screenFrames: [main, secondary],
            mainScreenFrame: main, margin: 24
        )
        let expectedHeight = OverlayController.panelHeight(fontScale: 2.0, availableHeight: 400, margin: 24)
        #expect(frame.height == expectedHeight)
    }

    @Test
    func resolvedShowFrameReconcilesScreenMismatchBetweenOriginAndFrameIntersection() {
        // origin 点はどの画面にも contains されないが、main 基準サイズの frame は
        // secondary と intersects する (secondary の外にわずかにドラッグされたケース)
        let main = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let secondary = NSRect(x: 1200, y: 0, width: 600, height: 1200)
        let frame = OverlayController.resolvedShowFrame(
            fontScale: 1.0, savedOrigin: NSPoint(x: 1050, y: 100), screenFrames: [main, secondary],
            mainScreenFrame: main, margin: 24
        )
        let expectedHeight = OverlayController.panelHeight(fontScale: 1.0, availableHeight: 1200, margin: 24)
        #expect(frame.height == expectedHeight)
        #expect(frame.minX >= secondary.minX)
        #expect(frame.maxX <= secondary.maxX)
    }

    @Test
    func resolvedShowFrameKeepsValidTargetScreenEvenWhenAnotherScreenAlsoIntersects() {
        // saved origin は secondary にのみ contains されるが、拡大後の frame は main とも
        // intersects しうる。screenFrames の先頭が main でも secondary を維持すべき
        let secondary = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let main = NSRect(x: 0, y: 800, width: 1000, height: 1000)
        let frame = OverlayController.resolvedShowFrame(
            fontScale: 2.0, savedOrigin: NSPoint(x: 100, y: 50), screenFrames: [main, secondary],
            mainScreenFrame: main, margin: 24
        )
        let expectedHeight = OverlayController.panelHeight(fontScale: 2.0, availableHeight: secondary.height, margin: 24)
        #expect(frame.height == expectedHeight)
    }

    @Test
    func targetScreenFrameUsesMainScreenWhenNoSavedOrigin() {
        let main = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let secondary = NSRect(x: 1000, y: 0, width: 600, height: 400)
        let target = OverlayController.targetScreenFrame(
            savedOrigin: nil, screenFrames: [main, secondary], mainScreenFrame: main
        )
        #expect(target == main)
    }

    @Test
    func targetScreenFrameUsesScreenContainingSavedOrigin() {
        let main = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let secondary = NSRect(x: 1000, y: 0, width: 600, height: 400)
        let target = OverlayController.targetScreenFrame(
            savedOrigin: NSPoint(x: 1200, y: 100), screenFrames: [main, secondary], mainScreenFrame: main
        )
        #expect(target == secondary)
    }

    @Test
    func targetScreenFrameFallsBackToMainWhenSavedOriginMatchesNoScreen() {
        let main = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let secondary = NSRect(x: 1000, y: 0, width: 600, height: 400)
        let target = OverlayController.targetScreenFrame(
            savedOrigin: NSPoint(x: 5000, y: 5000), screenFrames: [main, secondary], mainScreenFrame: main
        )
        #expect(target == main)
    }

    // resetPosition の契約はパネル非表示でも保存 origin を消すこと (defer が guard より先に登録される)。
    // defer の削除や guard 後への移動で「初期位置に戻す」が silent no-op になる regression を防ぐ
    @Test @MainActor
    func resetPositionClearsSavedOriginEvenWithoutPanel() {
        let defaults = UserDefaults.standard
        defaults.set(123.0, forKey: OverlayController.originXKey)
        defaults.set(45.0, forKey: OverlayController.originYKey)
        defer {
            defaults.removeObject(forKey: OverlayController.originXKey)
            defaults.removeObject(forKey: OverlayController.originYKey)
        }

        OverlayController().resetPosition(fontScale: 1.0)

        #expect(defaults.object(forKey: OverlayController.originXKey) == nil)
        #expect(defaults.object(forKey: OverlayController.originYKey) == nil)
    }
}
