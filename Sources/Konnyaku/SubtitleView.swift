import AppKit
import SwiftUI

struct SubtitleView: View {
    private static let volatileOpacity: Double = 0.65
    // ロールアップ 1 点あたりの表示滞在時間は containerHeight / speed。等倍で毎秒約
    // 2 行 (60pt) 進む速さなら読み流しと追いつきの両立が取れる
    private static let revealPointsPerSecond: CGFloat = 60

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

    @State private var revealOffset: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var containerSize: CGSize = .zero
    // パネルリサイズ中は折り返し起因で高さが跳ねるため、幅が動いた直後の高さ変化を
    // ロールアップ発火から除外する判定に使う (未計測は nil のままにして除外しない)
    @State private var measuredContainerWidth: CGFloat?

    private var isAdjusting: Bool {
        settings.isMovable && showsAdjustmentUI
    }

    var body: some View {
        // 上寄せは下寄せの鏡像 (ブロック順・行順とも反転して最新・最重要の翻訳を画面端
        // に固定する)。行順を保ったまま上寄せにすると、字幕全体が表示領域を超えたとき
        // 下端の最新行から溢れて「いま話している内容」が見えなくなる
        VStack(spacing: 8) {
            if !alignsToTop {
                sourceBlock
                translationBlock
            } else {
                translationBlock
                sourceBlock
            }
        }
        .offset(y: revealOffset)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { newHeight in
            handleContentHeightChange(newHeight)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignsToTop ? .top : .bottom)
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { newSize in
            containerSize = newSize
        }
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

    @ViewBuilder
    private var sourceBlock: some View {
        if !sourceLines.isEmpty {
            subtitleBlock(
                orderedForAlignment(sourceLines),
                size: 22 * settings.fontScale,
                weight: .semibold,
                color: .white.opacity(0.85)
            )
        }
    }

    @ViewBuilder
    private var translationBlock: some View {
        if !translationLines.isEmpty {
            subtitleBlock(
                orderedForAlignment(translationLines),
                size: 30 * settings.fontScale,
                weight: .bold,
                color: .white
            )
        }
    }

    // 表示行は末尾が最新。上寄せでは最新行が画面端 (上) 側に来るよう反転する
    private func orderedForAlignment(_ lines: [CaptionState.DisplayLine]) -> [CaptionState.DisplayLine] {
        alignsToTop ? lines.reversed() : lines
    }

    // 表示高を超える確定文が一度に届くと bottom 寄せでは文頭が一瞬も見えないため、
    // 追加分だけ下へずらした状態 (= 追加直前と同じ見え方) から等速で流し込む (ロールアップ)。
    // 幅計測値と不一致 (リサイズ直後) の高さ変化は折り返し起因のため発火しない。
    // 未計測 (nil) は幅変化ではないので除外しない (初回の一括長文を取りこぼさないため)
    nonisolated static func revealScrollDistance(
        previousContentHeight: CGFloat,
        contentHeight: CGFloat,
        containerSize: CGSize,
        measuredContainerWidth: CGFloat?
    ) -> CGFloat? {
        if let measuredContainerWidth, measuredContainerWidth != containerSize.width {
            return nil
        }
        let delta = contentHeight - previousContentHeight
        guard containerSize.height > 0, delta > containerSize.height else { return nil }
        return delta
    }

    private func handleContentHeightChange(_ newHeight: CGFloat) {
        // 上寄せ (鏡像) は最新行の文頭が常に画面端側に見えるためロールアップ不要で、
        // 行順反転のまま流すと読み順が末尾→先頭に逆転する。bottom 寄せ時のみ発火する
        let distance = alignsToTop
            ? nil
            : Self.revealScrollDistance(
                previousContentHeight: contentHeight,
                contentHeight: newHeight,
                containerSize: containerSize,
                measuredContainerWidth: measuredContainerWidth
            )
        let shrank = newHeight < contentHeight
        contentHeight = newHeight
        measuredContainerWidth = containerSize.width > 0 ? containerSize.width : nil
        var transaction = Transaction()
        transaction.disablesAnimations = true
        guard let distance else {
            // ロールアップ進行中に行失効で縮んだ場合、offset が残ると縮んだ内容が
            // ずれた位置に見え続けるため bottom 寄せへ即時復帰する
            if shrank {
                withTransaction(transaction) { revealOffset = 0 }
            }
            return
        }
        withTransaction(transaction) { revealOffset = distance }
        let duration = distance / (Self.revealPointsPerSecond * settings.fontScale)
        // 同一更新サイクル内で snap→animate すると最終値 (0) だけが評価されて
        // アニメーションごと消えうるため、戻しは次サイクルで開始する
        Task { @MainActor in
            withAnimation(.linear(duration: duration)) { revealOffset = 0 }
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
                    // 縦の fixedSize が無いと高さ不足時に Text が縦圧縮されて「…」省略される。
                    // 全高を確保し、超過分は寄せの反対側 (古い行側) からはみ出して隠す
                    .fixedSize(horizontal: false, vertical: true)
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
