import SwiftUI

struct SubtitleView: View {
    private static let volatileOpacity: Double = 0.65

    let state: CaptionState
    let settings: OverlaySettings

    var body: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            if settings.isMovable {
                movingHint
            }
            if !state.sourceDisplayLines.isEmpty {
                subtitleBlock(
                    state.sourceDisplayLines,
                    size: 22 * settings.fontScale,
                    weight: .semibold,
                    color: .white.opacity(0.85)
                )
            }
            if !state.translationDisplayLines.isEmpty {
                subtitleBlock(
                    state.translationDisplayLines,
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
    }

    private var movingHint: some View {
        Text(t("overlay.hint"))
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.orange)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.black.opacity(0.75), in: Capsule())
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
