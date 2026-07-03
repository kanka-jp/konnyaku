import AppKit
import SwiftUI
import Translation

struct SettingsView: View {
    let controller: AppController

    var body: some View {
        Form {
            Section(t("settings.section.language")) {
                Picker(t("settings.input_language"), selection: Binding(
                    get: { controller.languages.inputLocaleIdentifier },
                    set: { controller.setInputLanguage($0) }
                )) {
                    ForEach(controller.languages.availableInputs, id: \.identifier) { input in
                        Text(input.displayName).tag(input.identifier)
                    }
                }

                Picker(t("settings.output_language"), selection: Binding(
                    get: { controller.languages.outputLanguageIdentifier },
                    set: { controller.setOutputLanguage($0) }
                )) {
                    ForEach(controller.languages.availableOutputs, id: \.identifier) { output in
                        Text(output.displayName).tag(output.identifier)
                    }
                }
            }

            Section(t("settings.section.translation")) {
                if TranslationSupport.isLowLatencyStrategyAvailable {
                    Picker(t("settings.translation_strategy"), selection: Binding(
                        get: { controller.preferLowLatencyTranslation },
                        set: { controller.setPreferLowLatencyTranslation($0) }
                    )) {
                        Text(t("strategy.low_latency")).tag(true)
                        Text(t("strategy.high_fidelity")).tag(false)
                    }
                }

                Toggle(isOn: Binding(
                    get: { controller.realtimeTranslationEnabled },
                    set: { controller.setRealtimeTranslationEnabled($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t("settings.realtime_translation"))
                        Text(t("settings.realtime_translation.help"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section(t("settings.section.display")) {
                HStack {
                    Text(t("settings.font_size"))
                    Spacer()
                    Button {
                        controller.settings.decreaseFontScale()
                    } label: {
                        Image(systemName: "minus")
                    }
                    .disabled(!controller.settings.canDecreaseFontScale)

                    Text("\(Int(controller.settings.fontScale * 100))%")
                        .monospacedDigit()
                        .frame(minWidth: 44)

                    Button {
                        controller.settings.increaseFontScale()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(!controller.settings.canIncreaseFontScale)
                }
                .buttonStyle(.bordered)
            }

            Section(t("settings.section.correction")) {
                Toggle(t("settings.correction"), isOn: Binding(
                    get: { controller.correctionEnabled },
                    set: { controller.setCorrectionEnabled($0) }
                ))
                // 不可用時も OFF 方向の操作は許す (ON 保存済みのまま操作不能になるのを防ぐ)
                .disabled(!CorrectionEngine.isAvailable && !controller.correctionEnabled)

                if let reasonKey = CorrectionEngine.unavailableReasonKey {
                    Text(t(reasonKey))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Button(t("settings.edit_vocabulary")) {
                    controller.editVocabulary()
                }
            }

            Section(t("settings.section.general")) {
                Toggle(t("settings.auto_start"), isOn: Binding(
                    get: { controller.autoStartEnabled },
                    set: { controller.autoStartEnabled = $0 }
                ))
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 480)
        .onAppear {
            // メニューバー常駐 (LSUIElement) のため、開いた経路によらずここで activate
            // しないと設定ウィンドウが背面に開く
            NSApp.activate()
        }
        .task {
            await controller.loadLanguages()
        }
    }
}
