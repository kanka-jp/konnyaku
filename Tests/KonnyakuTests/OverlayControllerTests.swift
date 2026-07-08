import AppKit
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

    // モニター選択 (preferredScreenFrame) は savedOrigin が無い場合、mainScreenFrame より
    // 優先される契約。落ちる場合は Picker で選択したモニターが初回表示・リセット後の
    // デフォルト位置に反映されない regression
    @Test
    func resolvedShowFramePrefersPreferredScreenOverMainWhenNoSavedOrigin() {
        let main = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let preferred = NSRect(x: 1000, y: 0, width: 600, height: 400)
        let frame = OverlayController.resolvedShowFrame(
            fontScale: 1.0, savedOrigin: nil, savedSize: nil, screenFrames: [main, preferred],
            mainScreenFrame: main, margin: 24, preferredScreenFrame: preferred
        )
        #expect(frame.minX >= preferred.minX)
        #expect(frame.maxX <= preferred.maxX)
    }

    // savedOrigin がどの画面にも属さない (モニター構成変更等) 場合のフォールバックも
    // preferredScreenFrame を優先する契約
    @Test
    func resolvedShowFramePrefersPreferredScreenWhenSavedOriginMatchesNoScreen() {
        let main = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let preferred = NSRect(x: 1000, y: 0, width: 600, height: 400)
        let frame = OverlayController.resolvedShowFrame(
            fontScale: 1.0, savedOrigin: NSPoint(x: 5000, y: 5000), savedSize: nil,
            screenFrames: [main, preferred], mainScreenFrame: main, margin: 24,
            preferredScreenFrame: preferred
        )
        #expect(frame.minX >= preferred.minX)
        #expect(frame.maxX <= preferred.maxX)
    }

    // savedOrigin が実在するスクリーンに属する場合は、ドラッグ位置 (savedOrigin) を
    // preferredScreenFrame より優先する契約 (モニター選択後に手動調整した位置を尊重する)
    @Test
    func resolvedShowFrameKeepsSavedOriginScreenOverPreferredScreen() {
        let main = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let dragged = NSRect(x: 1000, y: 0, width: 600, height: 400)
        let frame = OverlayController.resolvedShowFrame(
            fontScale: 1.0, savedOrigin: NSPoint(x: 1100, y: 100), savedSize: nil,
            screenFrames: [main, dragged], mainScreenFrame: main, margin: 24,
            preferredScreenFrame: main
        )
        #expect(frame.minX >= dragged.minX)
        #expect(frame.maxX <= dragged.maxX)
    }

    @Test
    func screenFrameForDisplayIDReturnsMatchingFrame() {
        let main = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let secondary = NSRect(x: 1000, y: 0, width: 600, height: 400)
        let frame = OverlayController.screenFrame(
            forDisplayID: "secondary-id",
            in: [(id: "main-id", frame: main), (id: "secondary-id", frame: secondary)]
        )
        #expect(frame == secondary)
    }

    @Test
    func screenFrameForDisplayIDReturnsNilWhenNoMatch() {
        let main = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let frame = OverlayController.screenFrame(
            forDisplayID: "disconnected-id", in: [(id: "main-id", frame: main)]
        )
        #expect(frame == nil)
    }

    @Test
    func screenFrameForDisplayIDReturnsNilWhenIDIsNil() {
        let main = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let frame = OverlayController.screenFrame(forDisplayID: nil, in: [(id: "main-id", frame: main)])
        #expect(frame == nil)
    }

    // availableDisplays()/currentScreens() が共有する契約。落ちる場合は fallback ロジックが
    // 食い違い、Picker で選択したモニターが二度と解決できなくなる regression
    @Test
    func identifiedIDPrefersStableDisplayIDOverIndexFallback() {
        #expect(OverlayController.identifiedID(stableDisplayID: "uuid-123", index: 5) == "uuid-123")
    }

    @Test
    func identifiedIDFallsBackToIndexWhenStableDisplayIDMissing() {
        #expect(OverlayController.identifiedID(stableDisplayID: nil, index: 2) == "screen-2")
    }

    @Test
    func targetScreenFrameUsesMainScreenWhenNoSavedOrigin() {
        let main = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let secondary = NSRect(x: 1000, y: 0, width: 600, height: 400)
        let target = OverlayController.targetScreenFrame(
            savedOrigin: nil, screenFrames: [main, secondary], fallbackScreenFrame: main
        )
        #expect(target == main)
    }

    @Test
    func targetScreenFrameUsesScreenContainingSavedOrigin() {
        let main = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let secondary = NSRect(x: 1000, y: 0, width: 600, height: 400)
        let target = OverlayController.targetScreenFrame(
            savedOrigin: NSPoint(x: 1200, y: 100), screenFrames: [main, secondary], fallbackScreenFrame: main
        )
        #expect(target == secondary)
    }

    @Test
    func targetScreenFrameFallsBackToMainWhenSavedOriginMatchesNoScreen() {
        let main = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let secondary = NSRect(x: 1000, y: 0, width: 600, height: 400)
        let target = OverlayController.targetScreenFrame(
            savedOrigin: NSPoint(x: 5000, y: 5000), screenFrames: [main, secondary], fallbackScreenFrame: main
        )
        #expect(target == main)
    }

    // 調整モード外で key を許可すると、字幕表示中に他アプリのキーボードフォーカスを
    // 奪う (nonactivating panel は key になるとアプリ非 activate のまま入力を受ける)。
    // default false と toggle の往復を契約として固定する
    @Test @MainActor
    func adjustablePanelBecomesKeyOnlyWhileAdjusting() {
        let panel = AdjustablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        #expect(!panel.canBecomeKey)
        panel.allowsKeyWhileAdjusting = true
        #expect(panel.canBecomeKey)
        panel.allowsKeyWhileAdjusting = false
        #expect(!panel.canBecomeKey)
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
            mouseLocation: NSPoint(x: 1100, y: 100),
            screens: [(main, main), (secondary, secondary)], fallback: main
        )
        #expect(target == secondary)
    }

    @Test
    func dragTargetScreenFrameFallsBackWhenMouseMatchesNoScreen() {
        let main = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let target = OverlayController.dragTargetScreenFrame(
            mouseLocation: NSPoint(x: 5000, y: 5000), screens: [(main, main)], fallback: main
        )
        #expect(target == main)
    }

    // 内包判定が visibleFrame 基準だと menu bar / Dock 帯のマウスがどのスクリーンにも
    // 属さず fallback へ吸われ、別モニターへのドラッグが上端付近で妨げられる regression を防ぐ
    @Test
    func dragTargetScreenFramePicksScreenWhenMouseInMenuBarArea() {
        let mainFrame = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let mainVisible = NSRect(x: 0, y: 0, width: 1000, height: 775)
        let secondaryFrame = NSRect(x: 1000, y: 0, width: 600, height: 500)
        let secondaryVisible = NSRect(x: 1000, y: 0, width: 600, height: 475)
        let target = OverlayController.dragTargetScreenFrame(
            mouseLocation: NSPoint(x: 1100, y: 490),
            screens: [(mainFrame, mainVisible), (secondaryFrame, secondaryVisible)],
            fallback: mainVisible
        )
        #expect(target == secondaryVisible)
    }

    // 共有ビュー表示中の抑制契約: パネルは破棄せず表示だけを消し、解除で同じパネルが
    // 同じ frame のまま戻る。落ちる場合は共有ビューを閉じても字幕が戻らない (または
    // hide 相当に退化して解除時の即時復帰が壊れている)
    @Test @MainActor
    func setSuppressedHidesPanelWithoutDestroyingItAndRestoresOnRelease() throws {
        // CI runner に WindowServer が無い場合 show() は panel を作れないため対象外
        guard NSScreen.main != nil else { return }
        let controller = OverlayController()
        controller.show(
            state: CaptionState(), settings: OverlaySettings(config: [:]),
            languages: LanguageSettings(config: [:]), onFinishMoving: {}
        )
        defer { controller.hide() }
        let panel = try #require(controller.panel)
        #expect(panel.isVisible)
        controller.setSuppressed(true)
        #expect(!panel.isVisible)
        #expect(controller.panel === panel)
        controller.setSuppressed(false)
        #expect(panel.isVisible)
    }

    // 抑制中の show() (共有ビューを開いたまま字幕を開始) はパネルを作るだけで前面化せず、
    // 解除 (共有ビューを閉じる) が前面化する契約
    @Test @MainActor
    func showWhileSuppressedCreatesPanelWithoutOrderingFront() throws {
        guard NSScreen.main != nil else { return }
        let controller = OverlayController()
        controller.setSuppressed(true)
        controller.show(
            state: CaptionState(), settings: OverlaySettings(config: [:]),
            languages: LanguageSettings(config: [:]), onFinishMoving: {}
        )
        defer { controller.hide() }
        let panel = try #require(controller.panel)
        #expect(!panel.isVisible)
        controller.setSuppressed(false)
        #expect(panel.isVisible)
    }

    // stale savedOrigin (どのスクリーンとも intersects しない) + 画面幅級 savedSize の
    // fallback 復元経路。unclamped な default frame を返すと margin 分はみ出す regression を防ぐ
    @Test
    func resolvedShowFrameClampsOversizedSavedSizeWhenOriginMatchesNoScreen() {
        let main = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let frame = OverlayController.resolvedShowFrame(
            fontScale: 1.0, savedOrigin: NSPoint(x: 5000, y: 5000), savedSize: NSSize(width: 990, height: 790),
            screenFrames: [main], mainScreenFrame: main, margin: 24
        )
        #expect(frame.maxX <= main.maxX)
        #expect(frame.maxY <= main.maxY)
        #expect(frame.size == NSSize(width: 990, height: 790))
    }

    // savedOrigin なし + 画面幅級の savedSize (部分破損等) の復元経路。default origin
    // (margin, margin) のまま返すと margin 分はみ出す regression を防ぐ
    @Test
    func resolvedShowFrameClampsOversizedSavedSizeWithoutSavedOrigin() {
        let main = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let frame = OverlayController.resolvedShowFrame(
            fontScale: 1.0, savedOrigin: nil, savedSize: NSSize(width: 990, height: 790),
            screenFrames: [main], mainScreenFrame: main, margin: 24
        )
        #expect(frame.maxX <= main.maxX)
        #expect(frame.maxY <= main.maxY)
        #expect(frame.size == NSSize(width: 990, height: 790))
    }
}
