import SwiftUI

struct SubtitleView: View {
    private static let volatileOpacity: Double = 0.65

    let state: CaptionState
    let settings: OverlaySettings
    let languages: LanguageSettings

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
