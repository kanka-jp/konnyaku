import SwiftUI

struct MovingControlsView: View {
    let onFinishMoving: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(t("overlay.hint"))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.orange)
            Button {
                onFinishMoving()
            } label: {
                Text(t("overlay.done"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
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
}
