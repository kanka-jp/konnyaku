import SwiftUI
import Translation

// prepareTranslation の承認シート・進捗 UI は translationTask が載る view の
// ウィンドウに attach されるため、メニューバー label ではなく可視ウィンドウ上で実行する
struct ModelDownloadView: View {
    let controller: AppController

    var body: some View {
        // translationTask に渡した値そのものを closure に capture させ、完了通知の
        // 一致検証 (stale 上書き防止) が「この task を起動した configuration」と
        // 常に対応するようにする (closure 内で controller から読み直すと、差し替え
        // 直後の実行で新 configuration を拾う race がある)
        let downloadConfiguration = controller.modelDownloadConfiguration
        VStack(spacing: 12) {
            Text(t("status.model_downloading"))
            ProgressView()
                .progressViewStyle(.linear)
            if let elapsed = controller.modelDownloadElapsedText {
                Text(String(format: t("status.model_download_elapsed"), elapsed))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(t("status.model_download_hint"))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button(t("menu.open_language_settings")) {
                    controller.openTranslationLanguageSettings()
                }
                Button(t("menu.cancel_download")) {
                    controller.cancelModelDownload()
                }
            }
        }
        .padding(20)
        .frame(width: 420)
        .translationTask(downloadConfiguration) { session in
            // session はこの closure 内で逐次アクセスのみのため、isolation checking を
            // 外して nonisolated な prepareTranslation へ渡してよい
            nonisolated(unsafe) let session = session
            debugLog("model download started")
            do {
                try await session.prepareTranslation()
                guard !Task.isCancelled else { return }
                controller.modelDownloadSucceeded(for: downloadConfiguration)
            } catch {
                guard !Task.isCancelled else { return }
                if error is CancellationError || TranslationError.alreadyCancelled ~= error {
                    // 自 task の cancel は上の guard で除外済みなので、これは承認シート側の
                    // キャンセル。失敗扱いにすると自発的キャンセルに失敗 alert が出てしまう
                    guard downloadConfiguration == controller.modelDownloadConfiguration
                    else { return }
                    controller.cancelModelDownload()
                } else {
                    controller.modelDownloadFailed(error, for: downloadConfiguration)
                }
            }
        }
    }
}
