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
        engine.onPickerFailed = { [weak self] message in
            self?.presentAlert(message)
        }
        engine.onSourceSizeChanged = { [weak self] pixelSize in
            self?.followSourceAspect(pixelSize)
        }
    }

    private func beginCapture(with filter: SCContentFilter) {
        ensureWindow(sourceSizePoints: filter.contentRect.size)
        guard let contentView else { return }
        viewState.stoppedMessage = nil
        Task {
            // Task 実行前に windowWillClose → engine.stop() が完走していると、世代ガード
            // (開始中の停止のみ検出) をすり抜けてウィンドウ無しのキャプチャが残るため、
            // 開始時点で共有ビューが生きていることを確認する
            guard isOpen else { return }
            await engine.startCapture(
                with: filter, renderer: contentView.videoLayer.sampleBufferRenderer)
        }
    }

    private func showStopped(_ message: String) {
        if isOpen {
            viewState.stoppedMessage = message
        } else {
            // ウィンドウがまだ無い段階の失敗 (キャプチャ開始失敗等) は表示先が無いため alert
            presentAlert(message)
        }
    }

    private func presentAlert(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        NSApp.activate()
        alert.runModal()
    }

    private func ensureWindow(sourceSizePoints: CGSize) {
        if let window {
            // 再選択では新 stream のバッファが最初から新ソースサイズで作られ、リサイズ
            // 追従経路が発火しないため、ここで現フレームを新縦横比へ合わせ直す
            followSourceAspect(sourceSizePoints)
            window.makeKeyAndOrderFront(nil)
            // LSUIElement app は activate() 単発の前面化が cooperative で不確実
            // (SettingsWindowPresenter と同じ問題系)
            window.orderFrontRegardless()
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
        let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        // 初回作成でも followSourceAspect と同じく装飾 (タイトルバー) 込みで画面内に
        // 収める。window 生成前のため装飾高は class method で求める
        let probe = NSRect(x: 0, y: 0, width: 100, height: 100)
        let chrome = NSWindow.frameRect(forContentRect: probe, styleMask: styleMask).height
            - probe.height
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let contentSize = Self.initialContentSize(
            sourceSizePoints: sourceSizePoints,
            screenVisibleSize: NSSize(
                width: screenFrame.width, height: max(screenFrame.height - chrome, 1))
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: styleMask,
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
        // center() はフレームが visibleFrame をはみ出しても引き戻さない
        var frame = window.frame
        frame.origin = OverlayController.clampedOrigin(
            origin: frame.origin, size: frame.size, screenFrame: screenFrame)
        if frame != window.frame {
            window.setFrame(frame, display: false)
        }
        window.makeKeyAndOrderFront(nil)
        // LSUIElement app は activate しないとウィンドウが背面に開く。activate() 単発は
        // cooperative で不確実なため orderFrontRegardless も併用する
        window.orderFrontRegardless()
        NSApp.activate()
        self.window = window
        self.contentView = contentView
        isOpen = true
    }

    // contentAspectRatio はユーザーリサイズの制約のみで現フレームを変えないため、
    // それだけでは共有元の縦横比変化後に letterbox が Meet 配信へ残り続ける。
    // sourceSize は縦横比のみ使うため pt / px どちらの単位でもよい
    private func followSourceAspect(_ sourceSize: CGSize) {
        guard let window else { return }
        window.contentAspectRatio = sourceSize
        let screenFrame = (window.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        // 画面内クランプはタイトルバー等の装飾分を差し引いた高さで行う (content だけ
        // 画面高に収めても装飾込みフレームがはみ出すため)
        let chrome = window.frame.height - window.contentRect(forFrameRect: window.frame).height
        let currentWidth = window.contentRect(forFrameRect: window.frame).width
        window.setContentSize(
            Self.followedContentSize(
                currentWidth: currentWidth,
                sourceSize: sourceSize,
                screenVisibleSize: NSSize(
                    width: screenFrame.width, height: max(screenFrame.height - chrome, 1))
            ))
        // 拡大方向のリサイズでフレームが画面外へ出た場合は画面内へ引き戻す
        var frame = window.frame
        frame.origin = OverlayController.clampedOrigin(
            origin: frame.origin, size: frame.size, screenFrame: screenFrame)
        if frame != window.frame {
            window.setFrame(frame, display: true)
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        window = nil
        contentView = nil
        isOpen = false
        Task { await engine.stop() }
    }

    // 共有元の縦横比を保ちつつ画面の 6 割程度に収める。共有元より大きくは開かない
    // (拡大はぼやけるだけで益が無い)。contentMinSize (AppKit が強制する) を下回ると
    // 実ウィンドウが計算値と乖離して縦横比が崩れるため、両辺を満たす共通係数で拡大する
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
        let width = sourceSizePoints.width * scale
        let height = sourceSizePoints.height * scale
        let boost = max(minContentSize.width / width, minContentSize.height / height, 1)
        // 極端な縦長/横長ソースでは最小サイズ充足の拡大が画面を超えるため、画面内に収まる
        // ことを優先して縦横比を保って縮める (AppKit の contentMinSize 強制で生じうる
        // letterbox は許容 — 画面外に開いて操作不能になるより良い)
        let spill = max(
            width * boost / screenVisibleSize.width,
            height * boost / screenVisibleSize.height,
            1
        )
        // 整数 pt へ丸める (浮動小数の端数はウィンドウサイズとして無意味で、期待値の
        // 厳密比較を演算順序の変更に対して頑健にする)
        return NSSize(
            width: (width * boost / spill).rounded(),
            height: (height * boost / spill).rounded()
        )
    }

    // 現在の幅を保って高さを新縦横比に合わせる (最小サイズを下回る場合は縦横比を
    // 保ったまま両辺を拡大し、画面を超える場合は initialContentSize と同じく画面内を
    // 優先して縮める — ライブ共有中に画面外へ飛び出すのを防ぐ)
    nonisolated static func followedContentSize(
        currentWidth: CGFloat, sourceSize: CGSize, screenVisibleSize: CGSize
    ) -> NSSize {
        guard sourceSize.width > 1, sourceSize.height > 1 else { return minContentSize }
        let aspect = sourceSize.height / sourceSize.width
        var width = max(currentWidth, minContentSize.width)
        var height = width * aspect
        let boost = max(minContentSize.height / height, 1)
        width *= boost
        height *= boost
        guard screenVisibleSize.width > 1, screenVisibleSize.height > 1 else {
            return NSSize(width: width.rounded(), height: height.rounded())
        }
        let spill = max(width / screenVisibleSize.width, height / screenVisibleSize.height, 1)
        // 整数 pt へ丸める (initialContentSize と同じ理由)
        return NSSize(width: (width / spill).rounded(), height: (height / spill).rounded())
    }
}

@MainActor
@Observable
final class ShareViewState {
    var stoppedMessage: String?
}

// 映像は専用 view の backing layer として持つ。layer-backed view の layer へ手動
// addSublayer すると AppKit 管理の subview layer との z 順序が保証されず、字幕が映像の
// 背後に隠れうるため、順序が保証される subview の重なりで合成する
final class VideoHostView: NSView {
    var videoLayer: AVSampleBufferDisplayLayer {
        layer as! AVSampleBufferDisplayLayer
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func makeBackingLayer() -> CALayer {
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        return layer
    }
}

final class ShareContentView: NSView {
    private let videoHost = VideoHostView()
    private let overlayHost: NSHostingView<ShareOverlayView>

    var videoLayer: AVSampleBufferDisplayLayer {
        videoHost.videoLayer
    }

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
        addSubview(videoHost)
        addSubview(overlayHost)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        videoHost.frame = bounds
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
                // 半透過だと共有元消滅後も stale frame が Meet 視聴者に透けて見える
                .background(.black)
            }
        }
    }
}
