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
            fontScale: 1.0, savedOrigin: nil, savedSize: nil, screenFrames: [main], mainScreenFrame: main, margin: 24
        )
        #expect(frame == NSRect(x: 24, y: 24, width: 952, height: 380))
    }

    @Test
    func resolvedShowFrameFallsBackToMainDefaultWhenOriginAndFrameMatchNoScreen() {
        let main = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let frame = OverlayController.resolvedShowFrame(
            fontScale: 1.0, savedOrigin: NSPoint(x: 5000, y: 5000), savedSize: nil, screenFrames: [main], mainScreenFrame: main, margin: 24
        )
        #expect(frame.origin == NSPoint(x: 24, y: 24))
    }

    @Test
    func resolvedShowFrameClampsLargeHorizontalDragInsteadOfResettingToDefault() {
        let main = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let frame = OverlayController.resolvedShowFrame(
            fontScale: 1.0, savedOrigin: NSPoint(x: 100, y: 24), savedSize: nil, screenFrames: [main], mainScreenFrame: main, margin: 24
        )
        #expect(frame.origin == NSPoint(x: 48, y: 24))
    }

    @Test
    func resolvedShowFrameClampsLeftwardDragInsteadOfResettingToDefault() {
        let main = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let frame = OverlayController.resolvedShowFrame(
            fontScale: 1.0, savedOrigin: NSPoint(x: -10, y: 24), savedSize: nil, screenFrames: [main], mainScreenFrame: main, margin: 24
        )
        #expect(frame.origin == NSPoint(x: 0, y: 24))
    }

    @Test
    func resolvedShowFrameSizesForScreenContainingSavedOrigin() {
        let main = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let secondary = NSRect(x: 1000, y: 0, width: 600, height: 400)
        let frame = OverlayController.resolvedShowFrame(
            fontScale: 2.0, savedOrigin: NSPoint(x: 1200, y: 100), savedSize: nil, screenFrames: [main, secondary],
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
            fontScale: 1.0, savedOrigin: NSPoint(x: 1050, y: 100), savedSize: nil, screenFrames: [main, secondary],
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
            fontScale: 2.0, savedOrigin: NSPoint(x: 100, y: 50), savedSize: nil, screenFrames: [main, secondary],
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

    // resetFrame の契約はパネル非表示でも保存 origin/size を消すこと (defer が guard より先に登録される)。
    // defer の削除や guard 後への移動で「初期状態に戻す」が silent no-op になる regression を防ぐ
    @Test @MainActor
    func resetFrameClearsSavedFrameEvenWithoutPanel() {
        let defaults = UserDefaults.standard
        defaults.set(123.0, forKey: OverlayController.originXKey)
        defaults.set(45.0, forKey: OverlayController.originYKey)
        defaults.set(600.0, forKey: OverlayController.widthKey)
        defaults.set(300.0, forKey: OverlayController.heightKey)
        defer {
            defaults.removeObject(forKey: OverlayController.originXKey)
            defaults.removeObject(forKey: OverlayController.originYKey)
            defaults.removeObject(forKey: OverlayController.widthKey)
            defaults.removeObject(forKey: OverlayController.heightKey)
        }

        OverlayController().resetFrame(fontScale: 1.0)

        #expect(defaults.object(forKey: OverlayController.originXKey) == nil)
        #expect(defaults.object(forKey: OverlayController.originYKey) == nil)
        #expect(defaults.object(forKey: OverlayController.widthKey) == nil)
        #expect(defaults.object(forKey: OverlayController.heightKey) == nil)
    }

    // ユーザーが調整したサイズは fontScale 由来の自動サイズより優先する契約。
    // 落ちる場合は再起動・再表示でユーザーのリサイズ結果が失われている
    @Test
    func resolvedShowFrameUsesSavedSizeOverFontScaleDefault() {
        let main = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let frame = OverlayController.resolvedShowFrame(
            fontScale: 2.0, savedOrigin: NSPoint(x: 100, y: 50), savedSize: NSSize(width: 600, height: 300),
            screenFrames: [main], mainScreenFrame: main, margin: 24
        )
        #expect(frame.size == NSSize(width: 600, height: 300))
        #expect(frame.origin == NSPoint(x: 100, y: 50))
    }

    // 大きいモニターで保存したサイズを小さいモニターへ復元するケース。画面より大きい
    // まま復元すると本 PR が直す「見切れ」が復元経路で再発する
    @Test
    func resolvedShowFrameClampsSavedSizeToTargetScreen() {
        let main = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let secondary = NSRect(x: 1000, y: 0, width: 600, height: 400)
        let frame = OverlayController.resolvedShowFrame(
            fontScale: 1.0, savedOrigin: NSPoint(x: 1100, y: 100), savedSize: NSSize(width: 900, height: 700),
            screenFrames: [main, secondary], mainScreenFrame: main, margin: 24
        )
        #expect(frame.width <= secondary.width)
        #expect(frame.height <= secondary.height)
        #expect(frame.minX >= secondary.minX)
        #expect(frame.maxX <= secondary.maxX)
    }

    // 不正な保存値 (0 等) をそのまま使うとパネルが不可視になり、復旧手段がリセットしか
    // 無くなる。minPanelSize を下限として復元する契約
    @Test
    func resolvedShowFrameEnforcesMinimumSizeForCorruptedSavedSize() {
        let main = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let frame = OverlayController.resolvedShowFrame(
            fontScale: 1.0, savedOrigin: NSPoint(x: 24, y: 24), savedSize: NSSize(width: 0, height: 0),
            screenFrames: [main], mainScreenFrame: main, margin: 24
        )
        #expect(frame.size == OverlayController.minPanelSize)
    }

    // windowDidEndLiveResize の経路。リサイズで画面からはみ出た frame はサイズ縮小 →
    // origin 引き戻しの順で画面内へ収める (origin だけのクランプでは収まらない)
    @Test
    func clampedFrameShrinksOversizeThenPullsOriginBack() {
        let screen = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let clamped = OverlayController.clampedFrame(
            frame: NSRect(x: 700, y: 600, width: 1200, height: 900), screenFrame: screen
        )
        #expect(clamped == NSRect(x: 0, y: 0, width: 1000, height: 800))
    }

    @Test
    func clampedFrameKeepsInBoundsFrameUnchanged() {
        let screen = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let frame = NSRect(x: 100, y: 100, width: 600, height: 300)
        #expect(OverlayController.clampedFrame(frame: frame, screenFrame: screen) == frame)
    }

    // ドラッグ中のクランプ先選定。パネルの現在スクリーン基準だと境界を越えられず
    // 別モニターへ移動できなくなる (クランプ導入によるマルチモニター regression 防止)
    @Test
    func dragTargetScreenFramePicksScreenContainingMouse() {
        let main = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let secondary = NSRect(x: 1000, y: 0, width: 600, height: 400)
        let target = OverlayController.dragTargetScreenFrame(
            mouseLocation: NSPoint(x: 1100, y: 100), screenFrames: [main, secondary], fallback: main
        )
        #expect(target == secondary)
    }

    @Test
    func dragTargetScreenFrameFallsBackWhenMouseMatchesNoScreen() {
        let main = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let target = OverlayController.dragTargetScreenFrame(
            mouseLocation: NSPoint(x: 5000, y: 5000), screenFrames: [main], fallback: main
        )
        #expect(target == main)
    }
}
