import SwiftUI

struct MovingControlsView: View {
    let onFinishMoving: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(t("overlay.hint"))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.orange)
            Button(t("overlay.done")) {
                onFinishMoving()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.black.opacity(0.75), in: Capsule())
    }
}
