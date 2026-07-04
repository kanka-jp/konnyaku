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

    func show(state: CaptionState, settings: OverlaySettings) {
        if let panel {
            panel.orderFrontRegardless()
            return
        }
        guard let mainScreen = NSScreen.main else { return }
        let screenFrames = NSScreen.screens.map(\.visibleFrame)
        let saved = savedOrigin()
        let targetScreen = Self.targetScreenFrame(
            savedOrigin: saved, screenFrames: screenFrames, mainScreenFrame: mainScreen.visibleFrame
        )
        let height = Self.panelHeight(
            fontScale: settings.fontScale,
            availableHeight: targetScreen.height,
            margin: Self.margin
        )
        var frame = NSRect(
            x: targetScreen.minX + Self.margin,
            y: targetScreen.minY + Self.margin,
            width: targetScreen.width - Self.margin * 2,
            height: height
        )
        if let saved, let restored = Self.clampedRestoreOrigin(saved, size: frame.size, screenFrames: screenFrames) {
            frame.origin = restored
        }
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
        panel.contentView = NSHostingView(rootView: SubtitleView(state: state, settings: settings))
        panel.delegate = self
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
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

    // origin 点だけでなく frame が重なるスクリーンで判定する (origin 点のみだと左/下方向の
    // ドラッグで origin 自体が画面外に出て復元拒否になる)。見つからなければ既定位置にする
    nonisolated static func clampedRestoreOrigin(_ origin: NSPoint, size: NSSize, screenFrames: [NSRect]) -> NSPoint? {
        let frame = NSRect(origin: origin, size: size)
        guard let screenFrame = screenFrames.first(where: { $0.intersects(frame) }) else {
            return nil
        }
        return clampedOrigin(origin: origin, size: size, screenFrame: screenFrame)
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
