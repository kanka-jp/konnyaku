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
    func clampedRestoreOriginReturnsNilWhenOriginOutsideAllScreens() {
        let screen = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let result = OverlayController.clampedRestoreOrigin(
            NSPoint(x: 5000, y: 5000), size: NSSize(width: 952, height: 380), screenFrames: [screen]
        )
        #expect(result == nil)
    }

    @Test
    func clampedRestoreOriginClampsLargeHorizontalDragInsteadOfRejecting() {
        let screen = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let dragged = NSPoint(x: 100, y: 24)
        let result = OverlayController.clampedRestoreOrigin(
            dragged, size: NSSize(width: 952, height: 380), screenFrames: [screen]
        )
        #expect(result == NSPoint(x: 48, y: 24))
    }

    @Test
    func clampedRestoreOriginClampsLeftwardDragInsteadOfRejecting() {
        let screen = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let dragged = NSPoint(x: -10, y: 24)
        let result = OverlayController.clampedRestoreOrigin(
            dragged, size: NSSize(width: 952, height: 380), screenFrames: [screen]
        )
        #expect(result == NSPoint(x: 0, y: 24))
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
}
