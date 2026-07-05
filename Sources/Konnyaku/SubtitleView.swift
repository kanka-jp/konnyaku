import SwiftUI

struct SubtitleView: View {
    private static let volatileOpacity: Double = 0.65

    let state: CaptionState
    let settings: OverlaySettings
    let languages: LanguageSettings
    let onFinishMoving: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .overlay {
            if settings.isMovable {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.orange, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            }
        }
        // 操作 UI は調整対象のパネル内に出す (別の固定パネルだと、どのパネルを
        // 調整しているかとの視覚的な対応が切れる)。字幕は下寄せのため上部が空く
        .overlay(alignment: .top) {
            if settings.isMovable {
                MovingControlsView { onFinishMoving() }
                    .padding(.top, 14)
            }
        }
        .overlay {
            if settings.isMovable {
                ResizeCursorZones()
            }
        }
    }

    // 位置調整中に字幕が流れていないと枠線だけで実際の見え方が分からないため
    var showsPreview: Bool {
        settings.isMovable && state.sourceDisplayLines.isEmpty && state.translationDisplayLines.isEmpty
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

// borderless パネルでは AppKit がエッジホバー時のリサイズカーソルを出さないため、
// 調整モード中のみ辺・角に透明領域を重ねて方向別リサイズカーソルを示す。
// NSCursor.set() の手動管理は AppKit のカーソル更新に上書きされうるため、
// 宣言的な pointerStyle で SwiftUI にカーソル管理を委ねる
private struct ResizeCursorZones: View {
    private static let edgeThickness: CGFloat = 8
    private static let cornerSize: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            cursorZone(.top)
                .frame(width: max(0, width - Self.cornerSize * 2), height: Self.edgeThickness)
                .position(x: width / 2, y: Self.edgeThickness / 2)
            cursorZone(.bottom)
                .frame(width: max(0, width - Self.cornerSize * 2), height: Self.edgeThickness)
                .position(x: width / 2, y: height - Self.edgeThickness / 2)
            cursorZone(.leading)
                .frame(width: Self.edgeThickness, height: max(0, height - Self.cornerSize * 2))
                .position(x: Self.edgeThickness / 2, y: height / 2)
            cursorZone(.trailing)
                .frame(width: Self.edgeThickness, height: max(0, height - Self.cornerSize * 2))
                .position(x: width - Self.edgeThickness / 2, y: height / 2)
            cursorZone(.topLeading)
                .frame(width: Self.cornerSize, height: Self.cornerSize)
                .position(x: Self.cornerSize / 2, y: Self.cornerSize / 2)
            cursorZone(.topTrailing)
                .frame(width: Self.cornerSize, height: Self.cornerSize)
                .position(x: width - Self.cornerSize / 2, y: Self.cornerSize / 2)
            cursorZone(.bottomLeading)
                .frame(width: Self.cornerSize, height: Self.cornerSize)
                .position(x: Self.cornerSize / 2, y: height - Self.cornerSize / 2)
            cursorZone(.bottomTrailing)
                .frame(width: Self.cornerSize, height: Self.cornerSize)
                .position(x: width - Self.cornerSize / 2, y: height - Self.cornerSize / 2)
        }
    }

    private func cursorZone(_ position: FrameResizePosition) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .pointerStyle(.frameResize(position: position))
    }
}
