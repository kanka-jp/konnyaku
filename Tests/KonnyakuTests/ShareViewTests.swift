import AppKit
import Foundation
import Testing

@testable import Konnyaku

struct ShareViewControllerTests {
    @Test
    func initialContentSizePreservesSourceAspectRatio() {
        let size = ShareViewController.initialContentSize(
            sourceSizePoints: CGSize(width: 1600, height: 1000),
            screenVisibleSize: CGSize(width: 1512, height: 950)
        )
        #expect(abs(size.width / size.height - 1.6) < 0.001)
    }

    @Test
    func initialContentSizeShrinksLargeSourceToSixtyPercentOfScreen() {
        let size = ShareViewController.initialContentSize(
            sourceSizePoints: CGSize(width: 3000, height: 2000),
            screenVisibleSize: CGSize(width: 1500, height: 1000)
        )
        #expect(size.width == 900)
        #expect(size.height == 600)
    }

    @Test
    func initialContentSizeDoesNotUpscaleSmallSource() {
        let size = ShareViewController.initialContentSize(
            sourceSizePoints: CGSize(width: 600, height: 400),
            screenVisibleSize: CGSize(width: 3000, height: 2000)
        )
        #expect(size.width == 600)
        #expect(size.height == 400)
    }

    @Test
    func initialContentSizeEnforcesContentMinSizePreservingAspect() {
        // 200x100pt: 幅基準 (320) だと高さ 160 < contentMinSize.height (180) で AppKit の
        // 最小サイズ強制により縦横比が崩れるため、高さ基準の 1.8 倍で 360x180 になる
        let size = ShareViewController.initialContentSize(
            sourceSizePoints: CGSize(width: 200, height: 100),
            screenVisibleSize: CGSize(width: 1500, height: 1000)
        )
        #expect(size == NSSize(width: 360, height: 180))
        #expect(size.height >= ShareViewController.minContentSize.height)
    }

    @Test
    func initialContentSizeFallsBackOnDegenerateInput() {
        let size = ShareViewController.initialContentSize(
            sourceSizePoints: .zero,
            screenVisibleSize: CGSize(width: 1500, height: 1000)
        )
        #expect(size == NSSize(width: 960, height: 540))
    }

    @Test
    func followedContentSizeKeepsWidthAndAdjustsHeightToNewAspect() {
        let size = ShareViewController.followedContentSize(
            currentWidth: 800, sourceSize: CGSize(width: 1600, height: 1000))
        #expect(size == NSSize(width: 800, height: 500))
    }

    @Test
    func followedContentSizeEnforcesMinHeightPreservingAspect() {
        // 幅 400 のまま高さを 4:1 に合わせると 100 < 180 のため、縦横比を保って両辺拡大
        let size = ShareViewController.followedContentSize(
            currentWidth: 400, sourceSize: CGSize(width: 4000, height: 1000))
        #expect(size == NSSize(width: 720, height: 180))
    }
}

struct WindowCaptureEngineTests {
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
