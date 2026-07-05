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
                    .accessibilityLabel(t("settings.font_size.decrease"))

                    Text("\(Int((controller.settings.fontScale * 100).rounded()))%")
                        .monospacedDigit()
                        .frame(minWidth: 44)

                    Button {
                        controller.settings.increaseFontScale()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(!controller.settings.canIncreaseFontScale)
                    .accessibilityLabel(t("settings.font_size.increase"))
                }
                .buttonStyle(.bordered)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(t("settings.overlay_frame"))
                        Spacer()
                        Button(controller.settings.isMovable
                            ? t("settings.overlay_frame.finish")
                            : t("settings.overlay_frame.adjust")
                        ) {
                            controller.setOverlayMovable(!controller.settings.isMovable)
                        }
                        Button(t("settings.overlay_frame.reset")) {
                            controller.resetOverlayFrame()
                        }
                    }
                    .buttonStyle(.bordered)
                    Text(t("settings.overlay_frame.help"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Picker(t("settings.subtitle_placement"), selection: Binding(
                        get: { controller.settings.subtitlePlacement },
                        set: { controller.settings.subtitlePlacement = $0 }
                    )) {
                        Text(t("settings.subtitle_placement.overlay"))
                            .tag(OverlaySettings.SubtitlePlacement.overlay)
                        Text(t("settings.subtitle_placement.band"))
                            .tag(OverlaySettings.SubtitlePlacement.band)
                    }
                    Text(t("settings.subtitle_placement.help"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
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
            // メニューバー常駐 (LSUIElement) のため、開いた経路によらずここで activate +
            // 前面化しないと設定ウィンドウが背面に開く
            NSApp.activate()
            SettingsWindowPresenter.bringToFront()
        }
        .task {
            await controller.loadLanguages()
        }
    }
}

// macOS 14+ の activate() は cooperative で、非アクティブな LSUIElement アプリを前面化
// できないことがある (FB10184971) ため、activation の成否に依存せず前面化する
@MainActor
enum SettingsWindowPresenter {
    // SwiftUI が Settings scene のウィンドウに与える固定 identifier
    private static let windowIdentifier = "com_apple_SwiftUI_Settings_window"
    private static var pendingAttempts: [DispatchWorkItem] = []

    static func bringToFront() {
        // 初回オープンは menu ボタンと onAppear の双方から呼ばれるため、前回分を
        // 破棄して callback の重複実行を防ぐ
        for attempt in pendingAttempts { attempt.cancel() }
        pendingAttempts = []
        // openSettings() 直後はウィンドウの setup 完了前で前面化が上書きされうるため、
        // 時間差で数回試す
        let delays = [0, 100, 300]
        for delay in delays {
            let attempt = DispatchWorkItem {
                guard let window = NSApp.windows.first(where: {
                    $0.identifier?.rawValue == windowIdentifier
                }) else {
                    // setup 完了前の miss は正常系でも起きうるため、非公開 identifier の
                    // 変更で無音再発する事態の痕跡は最終 attempt の失敗のみ残す
                    if delay == delays.last {
                        debugLog("settings window not found by identifier (+\(delay)ms)")
                    }
                    return
                }
                // 遅延分は、ユーザーが直後に閉じたウィンドウを resurrect しないよう可視時のみ
                if delay > 0 && !window.isVisible { return }
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            }
            pendingAttempts.append(attempt)
            DispatchQueue.main.asyncAfter(
                deadline: .now() + .milliseconds(delay), execute: attempt)
        }
    }
}
