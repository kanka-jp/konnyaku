import Foundation
import Testing

@testable import Konnyaku

struct OverlayControllerTests {
    @Test
    func panelHeightScalesWithFontScale() {
        let base = OverlayController.panelHeight(fontScale: 1.0, availableHeight: 1000, margin: 24)
        let doubled = OverlayController.panelHeight(fontScale: 2.0, availableHeight: 1000, margin: 24)
        let expected = base * 2
        #expect(doubled == expected)
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
}
