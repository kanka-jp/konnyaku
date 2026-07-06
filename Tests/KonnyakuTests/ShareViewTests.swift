import AppKit
import Foundation
import Testing

@testable import Konnyaku

struct ShareViewControllerTests {
    @Test
    func followedContentSizeKeepsWidthAndAdjustsHeightToNewAspect() {
        let size = ShareViewController.followedContentSize(
            currentWidth: 800, sourceSize: CGSize(width: 1600, height: 1000),
            screenVisibleSize: CGSize(width: 1500, height: 1000))
        #expect(size == NSSize(width: 800, height: 500))
    }

    @Test
    func followedContentSizeEnforcesMinHeightPreservingAspect() {
        // 幅 400 のまま高さを 4:1 に合わせると 100 < 180 のため、縦横比を保って両辺拡大
        let size = ShareViewController.followedContentSize(
            currentWidth: 400, sourceSize: CGSize(width: 4000, height: 1000),
            screenVisibleSize: CGSize(width: 1500, height: 1000))
        #expect(size == NSSize(width: 720, height: 180))
    }

    @Test
    func followedContentSizeFitsExtremePortraitAspectOnScreen() {
        // 幅 320 のまま 1:10 に合わせると高さ 3200 で画面外のため、画面内優先で縮める
        let size = ShareViewController.followedContentSize(
            currentWidth: 320, sourceSize: CGSize(width: 200, height: 2000),
            screenVisibleSize: CGSize(width: 1500, height: 1000))
        #expect(size == NSSize(width: 100, height: 1000))
    }

    @Test
    func followedContentSizeAddsBandHeightToVideoAspect() {
        // band 配置: 高さ = 映像部 (幅 × 縦横比) + 帯の固定高
        let size = ShareViewController.followedContentSize(
            currentWidth: 800, sourceSize: CGSize(width: 1600, height: 1000),
            screenVisibleSize: CGSize(width: 1500, height: 1000), extraHeight: 160)
        #expect(size == NSSize(width: 800, height: 660))
    }

    @Test
    func followedContentSizeMinHeightBoostAppliesToVideoPortion() {
        // 映像部 80 < 180 のため映像部が最小高を満たすまで拡大する (合計 180 を下限に
        // すると contentMinSize = 180 + 帯高 の AppKit クランプと食い違う)
        let size = ShareViewController.followedContentSize(
            currentWidth: 320, sourceSize: CGSize(width: 4000, height: 1000),
            screenVisibleSize: CGSize(width: 1500, height: 1000), extraHeight: 60)
        #expect(size == NSSize(width: 720, height: 240))
    }

    @Test
    func followedContentSizeScreenClampAccountsForBandHeight() {
        // 帯込みの合計高が画面に収まるよう映像部を縮める: (1000-160)/10 = 84
        let size = ShareViewController.followedContentSize(
            currentWidth: 320, sourceSize: CGSize(width: 200, height: 2000),
            screenVisibleSize: CGSize(width: 1500, height: 1000), extraHeight: 160)
        #expect(size == NSSize(width: 84, height: 1000))
    }

    @Test
    func bandHeightScalesWithFontScale() {
        #expect(ShareViewController.bandHeight(fontScale: 1.0) == 160)
        #expect(ShareViewController.bandHeight(fontScale: 2.0) == 320)
    }

    // followSourceAspect の crash 回避は「resize increments の設定が既存の aspect
    // 制約を打ち消す」排他契約に依存する。契約が崩れると overlay → band 切替で
    // stale な比率制約が残るため、その検出として固定する
    @Test @MainActor
    func settingContentResizeIncrementsCancelsContentAspectRatio() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentAspectRatio = NSSize(width: 16, height: 9)
        window.contentResizeIncrements = NSSize(width: 1, height: 1)
        #expect(window.contentAspectRatio == .zero)
    }
}

struct WindowCaptureEngineTests {
    @Test
    func isShareableExcludesOwnAppUntitledTinyAndNonNormalLayerWindows() {
        let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        #expect(WindowCaptureEngine.isShareable(
            title: "Doc", ownerBundleID: "com.example.app", ownBundleID: "jp.kanka.konnyaku",
            frame: frame, layer: 0
        ))
        // 自アプリ (共有ビュー自身の無限ミラー防止)
        #expect(!WindowCaptureEngine.isShareable(
            title: "Konnyaku 共有ビュー", ownerBundleID: "jp.kanka.konnyaku",
            ownBundleID: "jp.kanka.konnyaku", frame: frame, layer: 0
        ))
        // タイトル無し / メニューバー等の非通常レイヤー / 極小ウィンドウ
        #expect(!WindowCaptureEngine.isShareable(
            title: nil, ownerBundleID: "com.example.app", ownBundleID: "jp.kanka.konnyaku",
            frame: frame, layer: 0
        ))
        #expect(!WindowCaptureEngine.isShareable(
            title: "Item-0", ownerBundleID: "com.example.app", ownBundleID: "jp.kanka.konnyaku",
            frame: frame, layer: 25
        ))
        #expect(!WindowCaptureEngine.isShareable(
            title: "Tiny", ownerBundleID: "com.example.app", ownBundleID: "jp.kanka.konnyaku",
            frame: CGRect(x: 0, y: 0, width: 40, height: 40), layer: 0
        ))
    }

    @Test
    func streamPixelSizeMultipliesPointsByScale() {
        let size = WindowCaptureEngine.streamPixelSize(
            contentSizePoints: CGSize(width: 800, height: 600),
            pointPixelScale: 2
        )
        #expect(size == CGSize(width: 1600, height: 1200))
    }

    @Test
    func streamPixelSizeClampsOversizedWindowPreservingAspectRatio() {
        let size = WindowCaptureEngine.streamPixelSize(
            contentSizePoints: CGSize(width: 5000, height: 3000),
            pointPixelScale: 2
        )
        #expect(size.width == WindowCaptureEngine.maxStreamDimension)
        // 10000x6000 を長辺 4096 に縮小: 6000 * 4096 / 10000 = 2457.6 → 2458
        #expect(size.height == 2458)
    }

    @Test
    func streamPixelSizeBoostsUndersizedWindowPreservingAspectRatio() {
        // 50x25pt @2x = 100x50px: 下限 64 を独立 clamp すると 100x64 で縦横比が崩れる。
        // 短辺基準の 1.28 倍で 128x64 になる
        let size = WindowCaptureEngine.streamPixelSize(
            contentSizePoints: CGSize(width: 50, height: 25),
            pointPixelScale: 2
        )
        #expect(size == CGSize(width: 128, height: 64))
    }

    @Test
    func nativePixelSizeRecoversOriginalSizeFromScaledFrame() {
        // 原寸 1000x800pt @2x のウィンドウが 0.5 倍で surface に描かれたフレーム
        let size = WindowCaptureEngine.nativePixelSize(
            contentRect: CGRect(x: 0, y: 0, width: 500, height: 400),
            contentScale: 0.5,
            scaleFactor: 2
        )
        #expect(size == CGSize(width: 2000, height: 1600))
    }

    @Test
    func nativePixelSizeRejectsDegenerateScaleAndRect() {
        #expect(WindowCaptureEngine.nativePixelSize(
            contentRect: CGRect(x: 0, y: 0, width: 500, height: 400),
            contentScale: 0, scaleFactor: 2
        ) == nil)
        #expect(WindowCaptureEngine.nativePixelSize(
            contentRect: .zero, contentScale: 1, scaleFactor: 2
        ) == nil)
    }

    @Test
    func shouldFollowResizeIgnoresSubToleranceDrift() {
        // 丸め誤差レベルの乖離で updateConfiguration が往復し続けない
        #expect(!WindowCaptureEngine.shouldFollowResize(
            native: CGSize(width: 1604, height: 1200),
            bufferSize: CGSize(width: 1600, height: 1200)
        ))
        #expect(WindowCaptureEngine.shouldFollowResize(
            native: CGSize(width: 1800, height: 1200),
            bufferSize: CGSize(width: 1600, height: 1200)
        ))
    }
}
