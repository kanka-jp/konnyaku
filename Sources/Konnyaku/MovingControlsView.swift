import SwiftUI

struct MovingControlsView: View {
    let onFinishMoving: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(t("overlay.hint"))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.orange)
                // 最小幅 (minPanelSize 320pt) のパネル内でもボタンごと収まるよう縮小を許す
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Button {
                onFinishMoving()
            } label: {
                Text(t("overlay.done"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(doneLabelColor)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Color.accentColor, in: Capsule())
            }
            // borderedProminent は key にならない nonactivating panel で inactive のグレー描画に
            // なり「完了」が読めない (実測) ため、window 状態に依存しない明示スタイルで描く
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.black.opacity(0.75), in: Capsule())
    }

    // システムの prominent ボタンと同じく、明るい accent (yellow 等) では白文字が
    // 低コントラストになるため輝度でラベル色を切り替える。sRGB 変換に失敗したら
    // 白に倒す (catalog color のまま component へ触ると例外になるため計算しない)
    private var doneLabelColor: Color {
        guard let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) else { return .white }
        let luminance = 0.299 * accent.redComponent + 0.587 * accent.greenComponent
            + 0.114 * accent.blueComponent
        return luminance > 0.65 ? .black : .white
    }
}
