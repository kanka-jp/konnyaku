import AppKit
import SwiftUI

@MainActor
final class OverlayController: NSObject, NSWindowDelegate {
    static let originXKey = "overlay.originX"
    static let originYKey = "overlay.originY"
    static let widthKey = "overlay.width"
    static let heightKey = "overlay.height"

    private static let margin: CGFloat = 24
    // 幅は字幕 2 行が読める最低限、高さは panelHeight の minimumHeight と揃える
    nonisolated static let minPanelSize = NSSize(width: 320, height: 200)

    private var panel: AdjustablePanel?
    private var onFinishMoving: (() -> Void)?

    // 最大 8 行 (上下段とも確定 3 行 + 話し中/追従 1 行) 分の基準高さを fontScale に比例させ
    // (等倍では旧固定値 380pt と一致)、拡大時の字幕欠け (下寄せのため上端から欠ける) を軽減する
    nonisolated static func panelHeight(fontScale: Double, availableHeight: CGFloat, margin: CGFloat) -> CGFloat {
        let baseHeight: CGFloat = 380
        // padding/spacing は fontScale で縮まないため、縮小時も最低限の行数を収める下限を設ける
        let minimumHeight: CGFloat = 200
        return min(max(minimumHeight, baseHeight * fontScale), availableHeight - margin * 2)
    }

    // 保存済み origin が属するスクリーンがあればその frame を使う (main 基準のままだと
    // より小さいセカンダリモニターへ復元する際に height がそのスクリーンに収まらない)
    nonisolated static func targetScreenFrame(savedOrigin: NSPoint?, screenFrames: [NSRect], mainScreenFrame: NSRect) -> NSRect {
        guard let savedOrigin else { return mainScreenFrame }
        return screenFrames.first(where: { $0.contains(savedOrigin) }) ?? mainScreenFrame
    }

    // origin の contains で決めた画面 (targetScreen) が候補 frame とまだ重なるなら維持し、
    // 重ならない場合のみ実際に重なる画面を探し直す (配列順で無関係な画面へ誤って上書きしないため)
    nonisolated static func resolvedShowFrame(
        fontScale: Double,
        savedOrigin: NSPoint?,
        savedSize: NSSize?,
        screenFrames: [NSRect],
        mainScreenFrame: NSRect,
        margin: CGFloat
    ) -> NSRect {
        // ユーザーが調整したサイズは fontScale 由来の自動サイズより優先する。上限は復元先
        // スクリーン (別モニターへの復元で画面より大きく戻さない)、下限は minPanelSize
        // (不正な保存値でパネルが見えなくなり復旧手段がリセットしか無くなるのを防ぐ)
        func defaultFrame(on screen: NSRect) -> NSRect {
            if let savedSize {
                let size = NSSize(
                    width: min(max(savedSize.width, minPanelSize.width), screen.width),
                    height: min(max(savedSize.height, minPanelSize.height), screen.height)
                )
                return NSRect(origin: NSPoint(x: screen.minX + margin, y: screen.minY + margin), size: size)
            }
            let height = panelHeight(fontScale: fontScale, availableHeight: screen.height, margin: margin)
            return NSRect(
                x: screen.minX + margin,
                y: screen.minY + margin,
                width: screen.width - margin * 2,
                height: height
            )
        }

        var targetScreen = targetScreenFrame(
            savedOrigin: savedOrigin, screenFrames: screenFrames, mainScreenFrame: mainScreenFrame
        )
        var frame = defaultFrame(on: targetScreen)

        guard let savedOrigin else {
            // savedSize のみ残存 (部分破損等) の場合、default origin + 画面幅級サイズで
            // margin 分はみ出しうるため、origin なしの経路でもクランプして返す
            frame.origin = clampedOrigin(origin: frame.origin, size: frame.size, screenFrame: targetScreen)
            return frame
        }
        let candidate = NSRect(origin: savedOrigin, size: frame.size)
        // targetScreen 自体が既に重なっているなら維持する (他のスクリーンも重なる場合に
        // 配列順で無関係な画面へ上書きしてしまうのを防ぐ)。重ならない場合のみ探し直す
        if !targetScreen.intersects(candidate) {
            guard let actualScreen = screenFrames.first(where: { $0.intersects(candidate) }) else {
                // モニター構成変更等で savedOrigin がどのスクリーンとも重ならない場合の
                // fallback。savedOrigin nil 経路と同様、画面幅級の savedSize で default
                // origin のまま返すと margin 分はみ出すためクランプする
                frame.origin = clampedOrigin(origin: frame.origin, size: frame.size, screenFrame: targetScreen)
                return frame
            }
            targetScreen = actualScreen
            frame = defaultFrame(on: targetScreen)
        }
        frame.origin = clampedOrigin(origin: savedOrigin, size: frame.size, screenFrame: targetScreen)
        return frame
    }

    func show(
        state: CaptionState,
        settings: OverlaySettings,
        languages: LanguageSettings,
        onFinishMoving: @escaping () -> Void
    ) {
        self.onFinishMoving = onFinishMoving
        if let panel {
            panel.orderFrontRegardless()
            return
        }
        guard let mainScreen = NSScreen.main else { return }
        let frame = Self.resolvedShowFrame(
            fontScale: settings.fontScale,
            savedOrigin: savedOrigin(),
            savedSize: savedSize(),
            screenFrames: NSScreen.screens.map(\.visibleFrame),
            mainScreenFrame: mainScreen.visibleFrame,
            margin: Self.margin
        )
        let panel = AdjustablePanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // mouseMoved は「key window + acceptsMouseMovedEvents」の両方が揃って初めて
        // 配送される。ここで常時 true にしても key でない通常時は届かないため無害
        panel.acceptsMouseMovedEvents = true
        panel.contentView = NSHostingView(
            rootView: SubtitleView(
                state: state, settings: settings, languages: languages,
                onFinishMoving: { [weak self] in self?.onFinishMoving?() }
            ))
        panel.delegate = self
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

    // setFrame が発火させる windowDidMove の再保存を defer の削除で打ち消し、
    // 未調整の初期状態 (保存 frame なし) に完全に戻す
    func resetFrame(fontScale: Double) {
        defer {
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: Self.originXKey)
            defaults.removeObject(forKey: Self.originYKey)
            defaults.removeObject(forKey: Self.widthKey)
            defaults.removeObject(forKey: Self.heightKey)
        }
        guard let panel, let mainScreen = NSScreen.main else { return }
        let frame = Self.resolvedShowFrame(
            fontScale: fontScale,
            savedOrigin: nil,
            savedSize: nil,
            screenFrames: NSScreen.screens.map(\.visibleFrame),
            mainScreenFrame: mainScreen.visibleFrame,
            margin: Self.margin
        )
        panel.setFrame(frame, display: true)
    }

    // origin が画面外にはみ出さない範囲にクランプする (はみ出す分だけ最小限ずらす。
    // reject-or-keep ではないため、わずかな水平ドラッグ位置も維持できる)
    nonisolated static func clampedOrigin(origin: NSPoint, size: NSSize, screenFrame: NSRect) -> NSPoint {
        let maxX = max(screenFrame.minX, screenFrame.maxX - size.width)
        let maxY = max(screenFrame.minY, screenFrame.maxY - size.height)
        return NSPoint(
            x: min(max(origin.x, screenFrame.minX), maxX),
            y: min(max(origin.y, screenFrame.minY), maxY)
        )
    }

    // サイズを先に画面内へ収めてから origin をクランプする (リサイズ終端とドラッグ中
    // 移動の共通経路。origin だけのクランプではパネルが画面より大きい場合に収まらない)
    nonisolated static func clampedFrame(frame: NSRect, screenFrame: NSRect) -> NSRect {
        var frame = frame
        frame.size.width = min(frame.width, screenFrame.width)
        frame.size.height = min(frame.height, screenFrame.height)
        frame.origin = clampedOrigin(origin: frame.origin, size: frame.size, screenFrame: screenFrame)
        return frame
    }

    // ドラッグ中のクランプ先はパネルの現在スクリーンではなくマウス位置のスクリーンにする
    // (現在スクリーンに閉じ込めるとパネルが境界を越えられず別モニターへ移動できない)。
    // 内包判定は menu bar / Dock を含む full frame で行う (visibleFrame 基準だと
    // その帯にマウスがある間どのスクリーンにも属さず、fallback へ引き戻されるため)
    nonisolated static func dragTargetScreenFrame(
        mouseLocation: NSPoint, screens: [(frame: NSRect, visibleFrame: NSRect)], fallback: NSRect
    ) -> NSRect {
        screens.first(where: { $0.frame.contains(mouseLocation) })?.visibleFrame ?? fallback
    }

    // origin を固定したまま高さだけ伸ばすと fontScale 拡大時にパネル上端が画面外へ
    // 出うるため、clampedOrigin で screenFrame 内に収める
    nonisolated static func resizedFrame(
        current: NSRect,
        fontScale: Double,
        screenFrame: NSRect,
        margin: CGFloat
    ) -> NSRect {
        var frame = current
        frame.size.height = panelHeight(fontScale: fontScale, availableHeight: screenFrame.height, margin: margin)
        frame.origin = clampedOrigin(origin: frame.origin, size: frame.size, screenFrame: screenFrame)
        return frame
    }

    func updateFontScale(_ fontScale: Double) {
        // ユーザーが明示的にサイズ調整済みならその領域を維持し、文字サイズだけ変える
        // (文字サイズ変更の副作用で調整済み領域が動く驚きを避ける)
        guard savedSize() == nil else { return }
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        let frame = Self.resizedFrame(
            current: panel.frame,
            fontScale: fontScale,
            screenFrame: screen.visibleFrame,
            margin: Self.margin
        )
        panel.setFrame(frame, display: true)
    }

    func setMovable(_ movable: Bool) {
        if let panel {
            // リサイズは調整モード中のみ許可する (通常時は ignoresMouseEvents で操作
            // 自体が届かないが、styleMask も揃えて契約を明示する)
            if movable {
                panel.styleMask.insert(.resizable)
                panel.minSize = Self.minPanelSize
                if let screen = panel.screen ?? NSScreen.main {
                    panel.maxSize = screen.visibleFrame.size
                }
            } else {
                panel.styleMask.remove(.resizable)
            }
            panel.ignoresMouseEvents = !movable
            panel.isMovableByWindowBackground = movable
            // mouseMoved の配送と NSCursor の反映は key window であることが前提
            // (非 key window では cursorUpdate が呼ばれず NSCursor.set も無視される)。
            // nonactivating panel はアプリを activate せずに key になれる (Spotlight 型)
            // ため、調整モード中のみ key を許可して makeKey する。通常時に key を許可
            // したままにすると他アプリ利用中のキーボードフォーカスを奪うため戻す
            panel.allowsKeyWhileAdjusting = movable
            if movable {
                panel.makeKey()
            } else if panel.isKeyWindow {
                panel.resignKey()
            }
        }
    }

    func windowDidMove(_ notification: Notification) {
        guard let panel else { return }
        // ライブドラッグは AppKit が画面外への持ち出しを制約しないため、移動のたびに
        // frame 全体を画面内へ引き戻す (パネルが画面より大きい場合はサイズも縮める)。
        // 本通知は setFrame 等のプログラム的な移動でも発火し、そのときのマウス位置は
        // 無関係なスクリーンにありうるため、クランプは実ドラッグ中 (調整モード + 左
        // ボタン押下) に限定する。リサイズ中は origin だけ動かすと反対側の辺がずれる
        // ため終端のクランプに任せる
        if !panel.inLiveResize,
            panel.isMovableByWindowBackground,
            NSEvent.pressedMouseButtons & 1 != 0
        {
            let fallback = (panel.screen ?? NSScreen.main)?.visibleFrame ?? .zero
            let target = Self.dragTargetScreenFrame(
                mouseLocation: NSEvent.mouseLocation,
                screens: NSScreen.screens.map { ($0.frame, $0.visibleFrame) },
                fallback: fallback
            )
            if !target.isEmpty {
                // リサイズ上限を調整開始時のスクリーンで固定せずドラッグ先へ追従させる
                panel.maxSize = target.size
                let clamped = Self.clampedFrame(frame: panel.frame, screenFrame: target)
                if clamped != panel.frame {
                    panel.setFrame(clamped, display: true)
                }
            }
        }
        // リサイズ中は保存しない (origin だけ先に保存すると、リサイズ完了前の異常終了で
        // 旧 size と不整合な組で復元されるため、windowDidEndLiveResize の一括保存に任せる)
        if !panel.inLiveResize {
            UserDefaults.standard.set(Double(panel.frame.origin.x), forKey: Self.originXKey)
            UserDefaults.standard.set(Double(panel.frame.origin.y), forKey: Self.originYKey)
        }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let panel else { return }
        if let screen = panel.screen ?? NSScreen.main {
            let clamped = Self.clampedFrame(frame: panel.frame, screenFrame: screen.visibleFrame)
            if clamped != panel.frame {
                panel.setFrame(clamped, display: true)
            }
        }
        let defaults = UserDefaults.standard
        defaults.set(Double(panel.frame.origin.x), forKey: Self.originXKey)
        defaults.set(Double(panel.frame.origin.y), forKey: Self.originYKey)
        defaults.set(Double(panel.frame.width), forKey: Self.widthKey)
        defaults.set(Double(panel.frame.height), forKey: Self.heightKey)
    }

    private func savedOrigin() -> NSPoint? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Self.originXKey) != nil,
              defaults.object(forKey: Self.originYKey) != nil else {
            return nil
        }
        return NSPoint(
            x: defaults.double(forKey: Self.originXKey),
            y: defaults.double(forKey: Self.originYKey)
        )
    }

    private func savedSize() -> NSSize? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Self.widthKey) != nil,
              defaults.object(forKey: Self.heightKey) != nil else {
            return nil
        }
        return NSSize(
            width: defaults.double(forKey: Self.widthKey),
            height: defaults.double(forKey: Self.heightKey)
        )
    }
}

// borderless window は canBecomeKey が既定 false で key になれず、mouseMoved の配送も
// NSCursor の反映も封じられる。nonactivating panel はアプリを activate せずに key に
// なれる (Spotlight 型) ため、調整モード中に限り key を許可してカーソル制御を成立させる
final class AdjustablePanel: NSPanel {
    var allowsKeyWhileAdjusting = false

    override var canBecomeKey: Bool {
        allowsKeyWhileAdjusting
    }
}
