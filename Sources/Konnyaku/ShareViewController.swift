import AppKit
import AVFoundation
import ScreenCaptureKit
import SwiftUI

// Meet 等の「ウィンドウ共有」には他プロセスのオーバーレイが映らないため、キャプチャ映像に
// 字幕を合成した自前ウィンドウを共有対象として提供する
@MainActor
@Observable
final class ShareViewController: NSObject, NSWindowDelegate {
    private(set) var isOpen = false

    @ObservationIgnored private let engine = WindowCaptureEngine()
    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private var contentView: ShareContentView?
    @ObservationIgnored private let viewState = ShareViewState()
    @ObservationIgnored private var deps: (state: CaptionState, settings: OverlaySettings, languages: LanguageSettings)?
    @ObservationIgnored private var isEngineConfigured = false

    nonisolated static let minContentSize = NSSize(width: 320, height: 180)

    func presentPicker(state: CaptionState, settings: OverlaySettings, languages: LanguageSettings) {
        deps = (state, settings, languages)
        configureEngineIfNeeded()
        engine.presentPicker()
    }

    func close() {
        window?.close()
    }

    private func configureEngineIfNeeded() {
        guard !isEngineConfigured else { return }
        isEngineConfigured = true
        engine.onSelection = { [weak self] filter in
            self?.beginCapture(with: filter)
        }
        engine.onStopped = { [weak self] message in
            self?.showStopped(message)
        }
        engine.onSourceSizeChanged = { [weak self] pixelSize in
            self?.window?.contentAspectRatio = pixelSize
        }
    }

    private func beginCapture(with filter: SCContentFilter) {
        ensureWindow(sourceSizePoints: filter.contentRect.size)
        guard let contentView else { return }
        viewState.stoppedMessage = nil
        Task {
            await engine.startCapture(
                with: filter, renderer: contentView.videoLayer.sampleBufferRenderer)
        }
    }

    private func showStopped(_ message: String) {
        if isOpen {
            viewState.stoppedMessage = message
        } else {
            // ウィンドウがまだ無い段階の失敗 (ピッカー起動失敗等) は表示先が無いため alert
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = message
            NSApp.activate()
            alert.runModal()
        }
    }

    private func ensureWindow(sourceSizePoints: CGSize) {
        if let window {
            window.contentAspectRatio = sourceSizePoints
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        guard let deps else { return }
        let contentView = ShareContentView(
            state: deps.state,
            settings: deps.settings,
            languages: deps.languages,
            viewState: viewState,
            onRepick: { [weak self] in self?.engine.presentPicker() }
        )
        let contentSize = Self.initialContentSize(
            sourceSizePoints: sourceSizePoints,
            screenVisibleSize: NSScreen.main?.visibleFrame.size ?? NSSize(width: 1280, height: 800)
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = t("shareview.title")
        window.contentAspectRatio = sourceSizePoints
        window.contentMinSize = Self.minContentSize
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentView = contentView
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        // LSUIElement app は activate しないとウィンドウが背面に開く
        NSApp.activate()
        self.window = window
        self.contentView = contentView
        isOpen = true
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        window = nil
        contentView = nil
        isOpen = false
        Task { await engine.stop() }
    }

    // 共有元の縦横比を保ちつつ画面の 6 割程度に収める。共有元より大きくは開かない
    // (拡大はぼやけるだけで益が無い)。極端に小さい共有元でも操作できる幅は確保する
    nonisolated static func initialContentSize(
        sourceSizePoints: CGSize, screenVisibleSize: CGSize
    ) -> NSSize {
        let fallback = NSSize(width: 960, height: 540)
        guard sourceSizePoints.width > 1, sourceSizePoints.height > 1,
              screenVisibleSize.width > 1, screenVisibleSize.height > 1 else { return fallback }
        let scale = min(
            screenVisibleSize.width * 0.6 / sourceSizePoints.width,
            screenVisibleSize.height * 0.6 / sourceSizePoints.height,
            1
        )
        let aspect = sourceSizePoints.height / sourceSizePoints.width
        let width = max(sourceSizePoints.width * scale, minContentSize.width)
        return NSSize(width: width, height: width * aspect)
    }
}

@MainActor
@Observable
final class ShareViewState {
    var stoppedMessage: String?
}

final class ShareContentView: NSView {
    let videoLayer = AVSampleBufferDisplayLayer()
    private let overlayHost: NSHostingView<ShareOverlayView>

    init(
        state: CaptionState,
        settings: OverlaySettings,
        languages: LanguageSettings,
        viewState: ShareViewState,
        onRepick: @escaping () -> Void
    ) {
        overlayHost = NSHostingView(
            rootView: ShareOverlayView(
                state: state, settings: settings, languages: languages,
                viewState: viewState, onRepick: onRepick
            ))
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        videoLayer.videoGravity = .resizeAspect
        layer?.addSublayer(videoLayer)
        addSubview(overlayHost)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        // ウィンドウリサイズへの追従で映像フレームが暗黙アニメーションで遅れて動くのを防ぐ
        CATransaction.setDisableActions(true)
        videoLayer.frame = bounds
        CATransaction.commit()
        overlayHost.frame = bounds
    }
}

struct ShareOverlayView: View {
    let state: CaptionState
    let settings: OverlaySettings
    let languages: LanguageSettings
    let viewState: ShareViewState
    let onRepick: () -> Void

    var body: some View {
        ZStack {
            SubtitleView(
                state: state, settings: settings, languages: languages,
                showsAdjustmentUI: false, onFinishMoving: {}
            )
            if let message = viewState.stoppedMessage {
                VStack(spacing: 12) {
                    Text(message)
                        .foregroundStyle(.white)
                    Button(t("shareview.repick")) {
                        onRepick()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black.opacity(0.75))
            }
        }
    }
}
