import AppKit
import SwiftUI

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
            Image(systemName: controller.state.isRunning ? "captions.bubble.fill" : "captions.bubble")
        }

        Window(Text(t("setup.title")), id: "translation-setup") {
            TranslationSetupView(languages: controller.languages) {
                controller.translationSetupCompleted()
            }
        }
        .windowResizability(.contentSize)
    }
}

private struct MenuContent: View {
    let controller: AppController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(controller.state.isRunning ? t("menu.stop") : t("menu.start")) {
            Task {
                await controller.toggle()
            }
        }
        .disabled(controller.isBusy)

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

        Button(t("menu.translation_setup")) {
            openWindow(id: "translation-setup")
            NSApp.activate(ignoringOtherApps: true)
        }

        Divider()

        Button(t("menu.quit")) {
            NSApp.terminate(nil)
        }
    }
}
