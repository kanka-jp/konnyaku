import SwiftUI

// AssetInventory の installation request は実 Progress を公開するため、
// determinate な進捗バー (%) で表示する
struct SpeechModelDownloadView: View {
    let controller: AppController

    var body: some View {
        VStack(spacing: 12) {
            Text(t("status.speech_model_downloading"))
            if let progress = controller.speechModelDownloadProgress {
                ProgressView(progress)
            }
            Button(t("menu.cancel_download")) {
                controller.cancelSpeechModelDownload()
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
