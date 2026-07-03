import AppKit
import SwiftUI
import Translation

@main
struct KonnyakuApp: App {
    @State private var controller = AppController()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: controller)
        } label: {
            // label は常駐 view のため、モデル DL の translationTask をここに載せると
            // メニューを開かなくてもバックグラウンドで DL が進む。
            // translationTask に渡した値そのものを closure に capture させ、完了通知の
            // 一致検証 (stale 上書き防止) が「この task を起動した configuration」と
            // 常に対応するようにする (closure 内で controller から読み直すと、差し替え
            // 直後の実行で新 configuration を拾う race がある)
            let downloadConfiguration = controller.modelDownloadConfiguration
            Image(systemName: menuBarSymbolName)
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
                        guard !(error is CancellationError), !Task.isCancelled else { return }
                        controller.modelDownloadFailed(error, for: downloadConfiguration)
                    }
                }
        }

        Settings {
            SettingsView(controller: controller)
        }
        .windowResizability(.contentSize)
    }

    private var menuBarSymbolName: String {
        if controller.state.isRunning { return "captions.bubble.fill" }
        if controller.isDownloadingModel { return "arrow.down.circle.dotted" }
        return "captions.bubble"
    }
}

private struct MenuContent: View {
    let controller: AppController
    @Environment(\.openSettings) private var openSettings

    private var startButtonTitle: String {
        if controller.state.isRunning { return t("menu.stop") }
        if controller.isDownloadingModel { return t("menu.cancel_download") }
        return t("menu.start")
    }

    var body: some View {
        Button(startButtonTitle) {
            Task {
                await controller.toggle()
            }
        }
        .disabled(controller.isBusy)

        if let message = controller.state.statusMessage {
            Text(message)
        }

        Divider()

        Toggle(t("menu.move_overlay"), isOn: Binding(
            get: { controller.settings.isMovable },
            set: { controller.setOverlayMovable($0) }
        ))
        .disabled(!controller.state.isRunning)

        Divider()

        Button(t("menu.settings")) {
            // 設定ウィンドウが既に開いて背面にある場合、SettingsView.onAppear は再発火
            // しない (再挿入されない) ため、メニュー経路ではここでも activate する
            NSApp.activate()
            openSettings()
        }

        Button(t("menu.quit")) {
            NSApp.terminate(nil)
        }
    }
}
