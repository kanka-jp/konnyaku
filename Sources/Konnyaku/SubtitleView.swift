import AppKit
import SwiftUI

struct SubtitleView: View {
    private static let volatileOpacity: Double = 0.65

    let state: CaptionState
    let settings: OverlaySettings
    let languages: LanguageSettings
    // 共有ビューでは調整モードの枠・操作 UI・プレビュー行を出さない (Meet の視聴者に
    // 映る面に管理 UI を混ぜない)
    var showsAdjustmentUI = true
    // 共有ビューの subtitle-position = top で上寄せにする (画面全体オーバーレイは
    // ドラッグで自由配置のため常に既定の下寄せ)
    var alignsToTop = false
    let onFinishMoving: () -> Void

    private var isAdjusting: Bool {
        settings.isMovable && showsAdjustmentUI
    }

    var body: some View {
        VStack(spacing: 8) {
            if !alignsToTop {
                Spacer(minLength: 0)
            }
            if !sourceLines.isEmpty {
                subtitleBlock(
                    sourceLines,
                    size: 22 * settings.fontScale,
                    weight: .semibold,
                    color: .white.opacity(0.85)
                )
            }
            if !translationLines.isEmpty {
                subtitleBlock(
                    translationLines,
                    size: 30 * settings.fontScale,
                    weight: .bold,
                    color: .white
                )
            }
            if alignsToTop {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignsToTop ? .top : .bottom)
        .overlay {
            if isAdjusting {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.orange, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            }
        }
        // 操作 UI は調整対象のパネル内に出す (別の固定パネルだと、どのパネルを
        // 調整しているかとの視覚的な対応が切れる)。字幕は下寄せのため上部が空く
        .overlay(alignment: .top) {
            if isAdjusting {
                MovingControlsView { onFinishMoving() }
                    .padding(.top, 14)
            }
        }
        .overlay {
            if isAdjusting {
                ResizeCursorTracking()
            }
        }
    }

    // 位置調整中に字幕が流れていないと枠線だけで実際の見え方が分からないため
    var showsPreview: Bool {
        isAdjusting && state.sourceDisplayLines.isEmpty && state.translationDisplayLines.isEmpty
    }

    var sourceLines: [CaptionState.DisplayLine] {
        showsPreview
            ? [CaptionState.DisplayLine(id: 0, text: t("overlay.preview_source"), kind: .final)]
            : state.sourceDisplayLines
    }

    var translationLines: [CaptionState.DisplayLine] {
        guard showsPreview else { return state.translationDisplayLines }
        // 翻訳無効 (入出力同一言語) だと実表示は source 1 段のみ。プレビューにだけ翻訳行を
        // 出すと bottom-align で実際より高い位置に合わせてしまうため、実表示と段数を揃える
        guard languages.isTranslationEnabled else { return [] }
        return [CaptionState.DisplayLine(id: 0, text: t("overlay.preview_translation"), kind: .final)]
    }

    private func subtitleBlock(_ lines: [CaptionState.DisplayLine], size: CGFloat, weight: Font.Weight, color: Color) -> some View {
        VStack(spacing: 2) {
            ForEach(lines) { line in
                Text(line.text)
                    .font(.system(size: size, weight: weight))
                    .foregroundStyle(color)
                    .opacity(line.kind == .volatile ? Self.volatileOpacity : 1)
                    .shadow(color: .black.opacity(0.8), radius: 1, x: 0, y: 1)
                    .lineLimit(2)
                    // 折り返し超過時は話し続けている最新語 (末尾) を優先表示する
                    .truncationMode(.head)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
    }
}

// 字幕パネルは通常 key window にならない (AdjustablePanel が調整モード中のみ key を
// 許可) ため、key window 前提の SwiftUI hover / pointerStyle 系は当てにできない
// (onHover / pointerStyle とも実機でカーソルが変わらないことを確認済み)。
// NSTrackingArea を .activeAlways で張り、mouseMoved で方向別カーソルを自前更新する
struct ResizeCursorTracking: NSViewRepresentable {
    func makeNSView(context: Context) -> TrackingView { TrackingView() }
    func updateNSView(_ nsView: TrackingView, context: Context) {}

    final class TrackingView: NSView {
        nonisolated static let edgeThickness: CGFloat = 8
        nonisolated static let cornerSize: CGFloat = 16

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
                owner: self,
                userInfo: nil
            ))
        }

        // クリック・背景ドラッグ・エッジリサイズのイベントを奪わない (tracking area の
        // enter/moved/exited は hit testing と独立に owner へ届くため nil でよい)
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func mouseEntered(with event: NSEvent) {
            updateCursor(with: event)
        }

        override func mouseMoved(with event: NSEvent) {
            updateCursor(with: event)
        }

        override func mouseExited(with event: NSEvent) {
            NSCursor.arrow.set()
        }

        // 調整モード解除等でホバー中にビューが外れた場合もリサイズカーソルを残さない
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil {
                NSCursor.arrow.set()
            }
        }

        private func updateCursor(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            if let position = Self.frameResizePosition(at: point, in: bounds) {
                NSCursor.frameResize(position: position, directions: .all).set()
            } else {
                NSCursor.arrow.set()
            }
        }

        // 非 flipped 座標 (y=0 が下端) 前提。角 (cornerSize 四方) を辺より優先する
        nonisolated static func frameResizePosition(
            at point: NSPoint, in bounds: NSRect
        ) -> NSCursor.FrameResizePosition? {
            let nearLeft = point.x <= bounds.minX + cornerSize
            let nearRight = point.x >= bounds.maxX - cornerSize
            let nearBottom = point.y <= bounds.minY + cornerSize
            let nearTop = point.y >= bounds.maxY - cornerSize
            if nearTop, nearLeft { return .topLeft }
            if nearTop, nearRight { return .topRight }
            if nearBottom, nearLeft { return .bottomLeft }
            if nearBottom, nearRight { return .bottomRight }
            if point.y >= bounds.maxY - edgeThickness { return .top }
            if point.y <= bounds.minY + edgeThickness { return .bottom }
            if point.x <= bounds.minX + edgeThickness { return .left }
            if point.x >= bounds.maxX - edgeThickness { return .right }
            return nil
        }
    }
}
