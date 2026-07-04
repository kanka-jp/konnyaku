import AppKit
import SwiftUI

@MainActor
final class OverlayController: NSObject, NSWindowDelegate {
    static let originXKey = "overlay.originX"
    static let originYKey = "overlay.originY"

    private static let margin: CGFloat = 24

    private var panel: NSPanel?

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
        screenFrames: [NSRect],
        mainScreenFrame: NSRect,
        margin: CGFloat
    ) -> NSRect {
        func defaultFrame(on screen: NSRect) -> NSRect {
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

        guard let savedOrigin else { return frame }
        let candidate = NSRect(origin: savedOrigin, size: frame.size)
        // targetScreen 自体が既に重なっているなら維持する (他のスクリーンも重なる場合に
        // 配列順で無関係な画面へ上書きしてしまうのを防ぐ)。重ならない場合のみ探し直す
        if !targetScreen.intersects(candidate) {
            guard let actualScreen = screenFrames.first(where: { $0.intersects(candidate) }) else {
                return frame
            }
            targetScreen = actualScreen
            frame = defaultFrame(on: targetScreen)
        }
        frame.origin = clampedOrigin(origin: savedOrigin, size: frame.size, screenFrame: targetScreen)
        return frame
    }

    func show(state: CaptionState, settings: OverlaySettings, onFinishMoving: @escaping () -> Void) {
        if let panel {
            panel.orderFrontRegardless()
            return
        }
        guard let mainScreen = NSScreen.main else { return }
        let frame = Self.resolvedShowFrame(
            fontScale: settings.fontScale,
            savedOrigin: savedOrigin(),
            screenFrames: NSScreen.screens.map(\.visibleFrame),
            mainScreenFrame: mainScreen.visibleFrame,
            margin: Self.margin
        )
        let panel = NSPanel(
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
        panel.contentView = NSHostingView(
            rootView: SubtitleView(state: state, settings: settings, onFinishMoving: onFinishMoving))
        panel.delegate = self
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

    // setFrame が発火させる windowDidMove の再保存を defer の削除で打ち消し、
    // 未ドラッグの初期状態 (保存 origin なし) に完全に戻す
    func resetPosition(fontScale: Double) {
        defer {
            UserDefaults.standard.removeObject(forKey: Self.originXKey)
            UserDefaults.standard.removeObject(forKey: Self.originYKey)
        }
        guard let panel, let mainScreen = NSScreen.main else { return }
        let frame = Self.resolvedShowFrame(
            fontScale: fontScale,
            savedOrigin: nil,
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
        panel?.ignoresMouseEvents = !movable
        panel?.isMovableByWindowBackground = movable
    }

    func windowDidMove(_ notification: Notification) {
        guard let panel else { return }
        UserDefaults.standard.set(Double(panel.frame.origin.x), forKey: Self.originXKey)
        UserDefaults.standard.set(Double(panel.frame.origin.y), forKey: Self.originYKey)
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
}
