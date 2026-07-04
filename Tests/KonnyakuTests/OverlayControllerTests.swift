import Foundation
import Testing

@testable import Konnyaku

struct OverlayControllerTests {
    @Test
    func panelHeightScalesWithFontScaleAboveMinimumFloor() {
        let base = OverlayController.panelHeight(fontScale: 1.5, availableHeight: 1000, margin: 24)
        let doubled = OverlayController.panelHeight(fontScale: 3.0, availableHeight: 1000, margin: 24)
        let expected = base * 2
        #expect(doubled == expected)
    }

    @Test
    func panelHeightAppliesMinimumFloorAtSmallFontScale() {
        let height = OverlayController.panelHeight(fontScale: 0.5, availableHeight: 1000, margin: 24)
        let expected: CGFloat = 380
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
        let height = OverlayController.panelHeight(fontScale: 2.0, availableHeight: 900, margin: 24)
        #expect(height > 380)
    }

    @Test
    func resizedFramePreservesOriginWhileGrowingHeight() {
        let current = NSRect(x: 24, y: 24, width: 952, height: 300)
        let resized = OverlayController.resizedFrame(current: current, fontScale: 2.0, availableHeight: 1000, margin: 24)
        #expect(resized.origin == current.origin)
        let expectedHeight = OverlayController.panelHeight(fontScale: 2.0, availableHeight: 1000, margin: 24)
        #expect(resized.height == expectedHeight)
    }

    @Test
    func resizedFrameClampsHeightToAvailableScreenHeight() {
        let current = NSRect(x: 24, y: 24, width: 952, height: 300)
        let resized = OverlayController.resizedFrame(current: current, fontScale: 2.0, availableHeight: 400, margin: 24)
        let expected: CGFloat = 352
        #expect(resized.height == expected)
    }

    @Test
    func fitsRejectsFrameThatOnlyPartiallyOverlapsScreen() {
        let screen = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let overflowing = NSRect(x: 900, y: 0, width: 200, height: 200)
        #expect(!OverlayController.fits(frame: overflowing, in: [screen]))
    }

    @Test
    func fitsAcceptsFrameFullyContainedInAScreen() {
        let screen = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let contained = NSRect(x: 24, y: 24, width: 952, height: 380)
        #expect(OverlayController.fits(frame: contained, in: [screen]))
    }
}
