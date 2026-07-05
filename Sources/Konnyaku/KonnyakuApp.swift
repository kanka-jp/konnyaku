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
            // DL の translationTask を label に載せると承認シートの attach 先ウィンドウが
            // 無く DL が始まらないため、ModelDownloadView (専用ウィンドウ) 側に置く
            Image(systemName: menuBarSymbolName)
                .symbolEffect(.variableColor.iterative, isActive: controller.isDownloadingModel)
                .task {
                    controller.autoStartIfEnabled()
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

        if controller.isDownloadingModel {
            Text(t("status.model_downloading"))
            if let elapsed = controller.modelDownloadElapsedText {
                Text(String(format: t("status.model_download_elapsed"), elapsed))
            }
            Button(t("menu.open_language_settings")) {
                controller.openTranslationLanguageSettings()
            }
        }

        if let message = controller.state.statusMessage {
            Text(message)
        }

        Divider()

        Toggle(t("menu.move_overlay"), isOn: Binding(
            get: { controller.settings.isMovable },
            set: { controller.setOverlayMovable($0) }
        ))

        Divider()

        Button(controller.isShareViewOpen ? t("menu.share_view.change") : t("menu.share_view")) {
            controller.openShareView()
        }
        if controller.isShareViewOpen {
            Button(t("menu.close_share_view")) {
                controller.closeShareView()
            }
        }

        Divider()

        Button(t("menu.settings")) {
            // 設定ウィンドウが既に開いて背面にある場合、SettingsView.onAppear は再発火
            // しない (再挿入されない) ため、メニュー経路ではここでも activate + 前面化する
            NSApp.activate()
            openSettings()
            SettingsWindowPresenter.bringToFront()
        }

        Button(t("menu.quit")) {
            NSApp.terminate(nil)
        }
    }
}
