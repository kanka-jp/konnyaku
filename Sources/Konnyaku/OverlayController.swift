import AppKit
import SwiftUI

@MainActor
final class OverlayController: NSObject, NSWindowDelegate {
    static let originXKey = "overlay.originX"
    static let originYKey = "overlay.originY"

    private static let margin: CGFloat = 24

    private var panel: NSPanel?

    // 最大 8 行 (上下段とも確定 3 行 + 話し中/追従 1 行) 分の基準高さを fontScale に比例させ、
    // 文字サイズ拡大時の字幕欠け (下寄せのため溢れると上端の古い行から欠ける) を軽減する
    nonisolated static func panelHeight(fontScale: Double, availableHeight: CGFloat, margin: CGFloat) -> CGFloat {
        let baseHeight: CGFloat = 300
        // padding/spacing は fontScale で縮まないため、縮小時も最低限の行数を収める下限を設ける
        let minimumHeight: CGFloat = 380
        return min(max(minimumHeight, baseHeight * fontScale), availableHeight - margin * 2)
    }

    func show(state: CaptionState, settings: OverlaySettings) {
        if let panel {
            panel.orderFrontRegardless()
            return
        }
        guard let screen = NSScreen.main else { return }
        let height = Self.panelHeight(
            fontScale: settings.fontScale,
            availableHeight: screen.visibleFrame.height,
            margin: Self.margin
        )
        var frame = NSRect(
            x: screen.visibleFrame.minX + Self.margin,
            y: screen.visibleFrame.minY + Self.margin,
            width: screen.visibleFrame.width - Self.margin * 2,
            height: height
        )
        if let restored = restoredOrigin(size: frame.size) {
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

    // NSRect は左下原点で SubtitleView は下寄せのため、origin はそのままに高さだけ
    // 更新すると字幕の画面上の位置を保ったまま表示領域が上方向に伸縮する
    nonisolated static func resizedFrame(
        current: NSRect,
        fontScale: Double,
        availableHeight: CGFloat,
        margin: CGFloat
    ) -> NSRect {
        var frame = current
        frame.size.height = panelHeight(fontScale: fontScale, availableHeight: availableHeight, margin: margin)
        return frame
    }

    func updateFontScale(_ fontScale: Double) {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        let frame = Self.resizedFrame(
            current: panel.frame,
            fontScale: fontScale,
            availableHeight: screen.visibleFrame.height,
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

    // fontScale 拡大でパネルが高くなり得るため、部分重複 (intersects) では画面外への
    // はみ出しを防げない。いずれかのスクリーンに完全に収まるかで判定する
    nonisolated static func fits(frame: NSRect, in screenFrames: [NSRect]) -> Bool {
        screenFrames.contains { $0.contains(frame) }
    }

    // 保存済み位置が現在のスクリーン構成に完全に収まる場合のみ復元する
    private func restoredOrigin(size: NSSize) -> NSPoint? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Self.originXKey) != nil,
              defaults.object(forKey: Self.originYKey) != nil else {
            return nil
        }
        let origin = NSPoint(
            x: defaults.double(forKey: Self.originXKey),
            y: defaults.double(forKey: Self.originYKey)
        )
        let frame = NSRect(origin: origin, size: size)
        let fits = Self.fits(frame: frame, in: NSScreen.screens.map(\.visibleFrame))
        return fits ? origin : nil
    }
}
