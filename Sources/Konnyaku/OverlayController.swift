import AppKit
import SwiftUI

@MainActor
final class OverlayController: NSObject, NSWindowDelegate {
    static let originXKey = "overlay.originX"
    static let originYKey = "overlay.originY"

    private var panel: NSPanel?

    func show(state: CaptionState, settings: OverlaySettings) {
        if let panel {
            panel.orderFrontRegardless()
            return
        }
        guard let screen = NSScreen.main else { return }
        let margin: CGFloat = 24
        // 複数行字幕 (上下段とも確定 3 行 + 話し中/追従 1 行 = 最大 8 行) 分。
        // 内容は下寄せのため、折り返しで溢れた場合は古い行側 (上端) から画面外に欠ける
        let height: CGFloat = 380
        var frame = NSRect(
            x: screen.visibleFrame.minX + margin,
            y: screen.visibleFrame.minY + margin,
            width: screen.visibleFrame.width - margin * 2,
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

    func setMovable(_ movable: Bool) {
        panel?.ignoresMouseEvents = !movable
        panel?.isMovableByWindowBackground = movable
    }

    func windowDidMove(_ notification: Notification) {
        guard let panel else { return }
        UserDefaults.standard.set(Double(panel.frame.origin.x), forKey: Self.originXKey)
        UserDefaults.standard.set(Double(panel.frame.origin.y), forKey: Self.originYKey)
    }

    // 保存済み位置が現在のスクリーン構成で見える場合のみ復元する
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
        let visible = NSScreen.screens.contains { screen in
            screen.visibleFrame.intersects(frame)
        }
        return visible ? origin : nil
    }
}
