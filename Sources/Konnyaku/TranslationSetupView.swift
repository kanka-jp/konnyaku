import SwiftUI
import Translation

struct TranslationSetupView: View {
    let languages: LanguageSettings
    var onInstalled: (() -> Void)?

    @State private var configuration: TranslationSession.Configuration?
    @State private var message = t("setup.message.initial")
    @State private var isDone = false
    @State private var isWorking = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text(t("setup.title"))
                .font(.headline)
            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
            if isDone {
                Button(t("setup.close")) {
                    dismiss()
                }
            } else {
                Button(t("setup.download")) {
                    isWorking = true
                    let requestedInput = languages.inputLocaleIdentifier
                    let requestedOutput = languages.outputLanguageIdentifier
                    Task {
                        // 翻訳 worker (resolvePair 済みペアで session を作る) と DL 対象を一致させる
                        let pair = await TranslationSupport.resolvePair(
                            input: languages.inputLocale.language,
                            output: languages.outputLanguage
                        )
                        // resolve 中に言語が変わった場合は旧ペアで configuration を再代入せず、
                        // onChange の reset (新ペアの DL 導線) を尊重する
                        guard requestedInput == languages.inputLocaleIdentifier,
                            requestedOutput == languages.outputLanguageIdentifier else {
                            isWorking = false
                            return
                        }
                        if var current = configuration,
                            current.source == pair.source, current.target == pair.target {
                            // 同一ペアの再試行: 同一 configuration では translationTask が
                            // 再発火しないため invalidate で明示的に再実行させる
                            current.invalidate()
                            configuration = current
                        } else {
                            configuration = TranslationSession.Configuration(
                                source: pair.source,
                                target: pair.target
                            )
                        }
                    }
                }
                .disabled(isWorking)
            }
        }
        .padding(24)
        .frame(width: 380)
        .onChange(of: languages.inputLocaleIdentifier) {
            resetForLanguageChange()
        }
        .onChange(of: languages.outputLanguageIdentifier) {
            resetForLanguageChange()
        }
        .translationTask(configuration) { session in
            // session はこの closure 内で逐次アクセスのみのため、isolation checking を外して nonisolated な prepareTranslation へ渡してよい
            nonisolated(unsafe) let session = session
            do {
                try await session.prepareTranslation()
                // DL 中の言語変更で configuration が差し替わると SwiftUI が本 task を
                // cancel する。旧ペアの完了で isDone / onInstalled を発火させない
                guard !Task.isCancelled else { return }
                message = t("setup.message.done")
                isDone = true
                onInstalled?()
            } catch {
                // 言語変更 / 再試行による task 差し替えの cancel は失敗ではないため、
                // onChange が戻した初期表示を stale な失敗メッセージで上書きしない。
                // cancel 経路の isWorking は cancel 元 (reset / 再試行 press) が管理する
                guard !(error is CancellationError), !Task.isCancelled else { return }
                message = "\(t("setup.message.failed")): \(error.localizedDescription)"
            }
            isWorking = false
        }
    }

    // 言語ペアが変わったら完了状態を破棄し、新ペアの DL 導線に戻す
    private func resetForLanguageChange() {
        configuration = nil
        isDone = false
        isWorking = false
        message = t("setup.message.initial")
    }
}
