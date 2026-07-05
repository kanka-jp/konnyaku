import AppKit
import AVFoundation
import Observation
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
    @ObservationIgnored private var reloadGeneration = 0

    nonisolated static let minContentSize = NSSize(width: 320, height: 180)
    nonisolated static let defaultContentSize = NSSize(width: 960, height: 540)

    func open(state: CaptionState, settings: OverlaySettings, languages: LanguageSettings) {
        deps = (state, settings, languages)
        configureEngineIfNeeded()
        if !WindowCaptureEngine.preflightScreenCaptureAccess() {
            // 未許可なら一度だけシステムダイアログが出る。判定はダイアログの結果でなく
            // preflight のみで行う (許可はアプリ再起動後に反映されるため、本セッション中は
            // 許可待ち表示のまま)
            _ = WindowCaptureEngine.requestScreenCaptureAccess()
        }
        viewState.needsPermission = !WindowCaptureEngine.preflightScreenCaptureAccess()
        ensureWindow()
        guard !viewState.needsPermission else { return }
        beginSelection()
    }

    func close() {
        window?.close()
    }

    private func configureEngineIfNeeded() {
        guard !isEngineConfigured else { return }
        isEngineConfigured = true
        engine.onStopped = { [weak self] message in
            self?.showStopped(message)
        }
        engine.onSourceSizeChanged = { [weak self] pixelSize in
            self?.followSourceAspect(pixelSize)
        }
    }

    private func beginSelection() {
        // 既存キャプチャは選択が確定するまで継続する (「共有元を変更…」中も配信を切らない)
        viewState.phase = .selecting
        reloadGeneration += 1
        let generation = reloadGeneration
        Task {
            guard isOpen else { return }
            await reloadWindows(generation: generation)
        }
    }

    private func reloadWindows(generation: Int) async {
        // 取得中の再オープン・「一覧を更新」連打で複数の取得が並行すると、完了順の逆転で
        // 古い結果 (失敗含む) が新しい成功を上書きしうるため、最新要求以外は書き込まない
        // (captureGeneration と同じ latest-wins パターン)
        guard generation == reloadGeneration else { return }
        viewState.windowListStatus = .loading
        do {
            let windows = try await engine.loadShareableWindows()
            guard generation == reloadGeneration else { return }
            viewState.windows = windows
            viewState.windowListStatus = .loaded
            debugLog("shareable windows: \(windows.count)")
        } catch {
            debugLog("load shareable windows failed: \(error)")
            guard generation == reloadGeneration else { return }
            viewState.windows = []
            viewState.windowListStatus = .failed
        }
    }

    private func selectWindow(_ target: WindowCaptureEngine.ShareableWindow) {
        guard let contentView else { return }
        viewState.phase = .capturing
        Task {
            // Task 実行前に windowWillClose → engine.stop() が完走していると、世代ガード
            // (開始中の停止のみ検出) をすり抜けてウィンドウ無しのキャプチャが残るため、
            // 開始時点で共有ビューが生きていることを確認する
            guard isOpen else { return }
            await engine.startCapture(
                windowID: target.id, renderer: contentView.videoLayer.sampleBufferRenderer)
        }
    }

    private func openScreenCaptureSettings() {
        let pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        if let url = URL(string: pane) {
            NSWorkspace.shared.open(url)
        }
    }

    private func showStopped(_ message: String) {
        guard isOpen else { return }
        viewState.phase = .stopped(message)
    }

    private func ensureWindow() {
        if let window {
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
            actions: ShareViewActions(
                onSelect: { [weak self] target in self?.selectWindow(target) },
                onReselect: { [weak self] in self?.beginSelection() },
                onOpenSettings: { [weak self] in self?.openScreenCaptureSettings() }
            )
        )
        let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        // 装飾 (タイトルバー) 込みで画面内に収める。window 生成前のため装飾高は class
        // method で求める
        let probe = NSRect(x: 0, y: 0, width: 100, height: 100)
        let chrome = NSWindow.frameRect(forContentRect: probe, styleMask: styleMask).height
            - probe.height
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let contentSize = NSSize(
            width: min(Self.defaultContentSize.width, screenFrame.width),
            height: min(Self.defaultContentSize.height, max(screenFrame.height - chrome, 1))
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.title = t("shareview.title")
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

    // 現在の幅を保って高さを新縦横比に合わせる (最小サイズを下回る場合は縦横比を
    // 保ったまま両辺を拡大し、画面を超える場合は画面内を優先して縮める — ライブ共有中に
    // 画面外へ飛び出すのを防ぐ)
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
        // 整数 pt へ丸める (浮動小数の端数はウィンドウサイズとして無意味で、期待値の
        // 厳密比較を演算順序の変更に対して頑健にする)
        return NSSize(width: (width / spill).rounded(), height: (height / spill).rounded())
    }
}

@MainActor
@Observable
final class ShareViewState {
    enum Phase: Equatable {
        case selecting
        case capturing
        case stopped(String)
    }

    // 取得失敗を空一覧 (「見つかりません」) と区別して表示するための状態
    enum WindowListStatus: Equatable {
        case loading
        case loaded
        case failed
    }

    var phase: Phase = .selecting
    var windows: [WindowCaptureEngine.ShareableWindow] = []
    var windowListStatus: WindowListStatus = .loading
    var needsPermission = false
}

struct ShareViewActions {
    let onSelect: (WindowCaptureEngine.ShareableWindow) -> Void
    let onReselect: () -> Void
    let onOpenSettings: () -> Void
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
        actions: ShareViewActions
    ) {
        overlayHost = NSHostingView(
            rootView: ShareOverlayView(
                state: state, settings: settings, languages: languages,
                viewState: viewState, actions: actions
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
    let actions: ShareViewActions

    var body: some View {
        ZStack {
            SubtitleView(
                state: state, settings: settings, languages: languages,
                showsAdjustmentUI: false, onFinishMoving: {}
            )
            if viewState.needsPermission {
                PermissionRequestView(onOpenSettings: actions.onOpenSettings)
            } else {
                switch viewState.phase {
                case .selecting:
                    WindowSelectView(
                        windows: viewState.windows,
                        status: viewState.windowListStatus,
                        onSelect: actions.onSelect,
                        onRefresh: actions.onReselect
                    )
                case .capturing:
                    EmptyView()
                case .stopped(let message):
                    VStack(spacing: 12) {
                        Text(message)
                            .foregroundStyle(.white)
                        Button(t("shareview.repick")) {
                            actions.onReselect()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // 半透過だと共有元消滅後も stale frame が Meet 視聴者に透けて見える
                    .background(.black)
                    .environment(\.colorScheme, .dark)
                }
            }
        }
    }
}

// ウィンドウ前面化のクリックやスクロール操作が一覧の行に落ちて誤選択しないよう、
// 「行クリックで選択 → 開始ボタンで確定」の 2 段階にする
struct WindowSelectView: View {
    let windows: [WindowCaptureEngine.ShareableWindow]
    let status: ShareViewState.WindowListStatus
    let onSelect: (WindowCaptureEngine.ShareableWindow) -> Void
    let onRefresh: () -> Void

    @State private var selectedID: CGWindowID?

    var body: some View {
        VStack(spacing: 12) {
            Text(t("shareview.select_window"))
                .font(.headline)
                .foregroundStyle(.white)
            if status == .loading {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxHeight: .infinity)
            } else if status == .failed {
                Text(t("shareview.load_failed"))
                    .foregroundStyle(.secondary)
            } else if windows.isEmpty {
                Text(t("shareview.no_windows"))
                    .foregroundStyle(.secondary)
            } else {
                List(windows, selection: $selectedID) { window in
                    HStack(spacing: 10) {
                        Group {
                            if let thumbnail = window.thumbnail {
                                Image(decorative: thumbnail, scale: 1)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                            } else {
                                Image(systemName: "macwindow")
                                    .font(.title)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 120, height: 68)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(window.title)
                                .lineLimit(1)
                            Text(window.appName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 16)
            }
            HStack(spacing: 12) {
                Button(t("shareview.refresh")) {
                    selectedID = nil
                    onRefresh()
                }
                Button(t("shareview.start_share")) {
                    if let selected = windows.first(where: { $0.id == selectedID }) {
                        onSelect(selected)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedID == nil || !windows.contains { $0.id == selectedID })
            }
        }
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        // 黒背景固定のため、ライト外観だと List 行や Button の既定文字色 (黒系) が溶ける
        .environment(\.colorScheme, .dark)
    }
}

struct PermissionRequestView: View {
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text(t("shareview.permission_needed"))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button(t("alert.open_settings")) {
                onOpenSettings()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .environment(\.colorScheme, .dark)
    }
}
