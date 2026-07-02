import AppKit
import SwiftUI
import Translation

@main
struct KonnyakuApp: App {
    @State private var controller = AppController()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: controller)
                .task {
                    await controller.loadLanguages()
                }
        } label: {
            // label は常駐 view のため、モデル DL の translationTask をここに載せると
            // メニューを開かなくてもバックグラウンドで DL が進む
            Image(systemName: menuBarSymbolName)
                .translationTask(controller.modelDownloadConfiguration) { session in
                    // session はこの closure 内で逐次アクセスのみのため、isolation checking を
                    // 外して nonisolated な prepareTranslation へ渡してよい
                    nonisolated(unsafe) let session = session
                    debugLog("model download started")
                    do {
                        try await session.prepareTranslation()
                        // DL 中の言語変更で configuration が差し替わると本 task は
                        // cancel される。旧ペアの完了で自動開始しない
                        guard !Task.isCancelled else { return }
                        await controller.modelDownloadSucceeded()
                    } catch {
                        guard !(error is CancellationError), !Task.isCancelled else { return }
                        controller.modelDownloadFailed(error)
                    }
                }
        }
    }

    private var menuBarSymbolName: String {
        if controller.state.isRunning { return "captions.bubble.fill" }
        if controller.isDownloadingModel { return "arrow.down.circle.dotted" }
        return "captions.bubble"
    }
}

private struct MenuContent: View {
    let controller: AppController

    var body: some View {
        Button(controller.state.isRunning ? t("menu.stop") : t("menu.start")) {
            Task {
                await controller.toggle()
            }
        }
        .disabled(controller.isBusy)

        if controller.isDownloadingModel {
            Text(t("status.model_downloading"))
        }

        if let message = controller.state.statusMessage {
            Text(message)
        }

        Divider()

        Picker(t("menu.input_language"), selection: Binding(
            get: { controller.languages.inputLocaleIdentifier },
            set: { controller.setInputLanguage($0) }
        )) {
            ForEach(controller.languages.availableInputs, id: \.identifier) { input in
                Text(input.displayName).tag(input.identifier)
            }
        }

        Picker(t("menu.output_language"), selection: Binding(
            get: { controller.languages.outputLanguageIdentifier },
            set: { controller.setOutputLanguage($0) }
        )) {
            ForEach(controller.languages.availableOutputs, id: \.identifier) { output in
                Text(output.displayName).tag(output.identifier)
            }
        }

        if TranslationSupport.isLowLatencyStrategyAvailable {
            Picker(t("menu.translation_strategy"), selection: Binding(
                get: { controller.preferLowLatencyTranslation },
                set: { controller.setPreferLowLatencyTranslation($0) }
            )) {
                Text(t("strategy.low_latency")).tag(true)
                Text(t("strategy.high_fidelity")).tag(false)
            }
        }

        Divider()

        Toggle(t("menu.move_overlay"), isOn: Binding(
            get: { controller.settings.isMovable },
            set: { controller.setOverlayMovable($0) }
        ))
        .disabled(!controller.state.isRunning)

        Picker(t("menu.font_size"), selection: Binding(
            get: { controller.settings.fontScale },
            set: { controller.settings.fontScale = $0 }
        )) {
            ForEach(OverlaySettings.fontScales) { scale in
                Text(t(scale.labelKey)).tag(scale.id)
            }
        }

        Divider()

        Toggle(t("menu.correction"), isOn: Binding(
            get: { controller.correctionEnabled },
            set: { controller.setCorrectionEnabled($0) }
        ))
        // 不可用時も OFF 方向の操作は許す (ON 保存済みのまま操作不能になるのを防ぐ)
        .disabled(!CorrectionEngine.isAvailable && !controller.correctionEnabled)

        if let reasonKey = CorrectionEngine.unavailableReasonKey {
            Text(t(reasonKey))
        }

        Button(t("menu.edit_vocabulary")) {
            controller.editVocabulary()
        }

        Divider()

        Button(t("menu.quit")) {
            NSApp.terminate(nil)
        }
    }
}
