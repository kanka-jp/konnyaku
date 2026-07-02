import AppKit
import Foundation
import Observation
import Translation

@MainActor
@Observable
final class AppController {
    let state = CaptionState()
    let settings = OverlaySettings()
    let languages = LanguageSettings()

    static let correctionEnabledKey = "correction.enabled"

    private let overlay = OverlayController()
    private var pipeline: CaptionPipeline?
    private(set) var isBusy = false
    private(set) var needsTranslationSetup = false
    private var isStarting = false
    private var pendingLanguageRestart = false

    var correctionEnabled: Bool {
        didSet {
            UserDefaults.standard.set(correctionEnabled, forKey: Self.correctionEnabledKey)
        }
    }

    init() {
        correctionEnabled = UserDefaults.standard.bool(forKey: Self.correctionEnabledKey)
    }

    func loadLanguages() async {
        await languages.loadAvailable()
    }

    func setCorrectionEnabled(_ enabled: Bool) {
        correctionEnabled = enabled
        scheduleLanguageRestart()
    }

    func editVocabulary() {
        do {
            try VocabularyStore.ensureFileExists()
            NSWorkspace.shared.open(VocabularyStore.fileURL)
        } catch {
            state.statusMessage = "\(t("status.vocabulary_error")): \(error.localizedDescription)"
        }
    }

    func setOverlayMovable(_ movable: Bool) {
        settings.isMovable = movable
        overlay.setMovable(movable)
    }

    func setInputLanguage(_ identifier: String) {
        languages.inputLocaleIdentifier = identifier
        scheduleLanguageRestart()
    }

    func setOutputLanguage(_ identifier: String) {
        languages.outputLanguageIdentifier = identifier
        scheduleLanguageRestart()
    }

    func translationSetupCompleted() {
        needsTranslationSetup = false
        state.statusMessage = nil
    }

    func toggle() async {
        if state.isRunning {
            await stop()
        } else {
            await start()
        }
    }

    func start() async {
        guard !state.isRunning, !isBusy else { return }
        isBusy = true
        isStarting = true
        defer {
            isStarting = false
            isBusy = false
            consumePendingLanguageRestart()
        }
        state.statusMessage = nil
        needsTranslationSetup = false

        // start 全体で同じ設定を使う (途中の変更は pendingLanguageRestart 経由の
        // 再起動で反映し、チェック済み設定と起動設定の食い違いを防ぐ)
        let inputLocale = languages.inputLocale
        let outputLanguage = languages.outputLanguage
        let translationEnabled = languages.isTranslationEnabled
        let correctionEnabled = self.correctionEnabled

        guard await AudioCaptureEngine.requestMicrophoneAccess() else {
            state.statusMessage = t("status.mic_denied")
            return
        }

        if translationEnabled {
            // 実翻訳セッション (CaptionPipeline の worker) と同じ resolvePair 済みペアで
            // 可用性を判定し、チェック対象とセッション対象の不一致を防ぐ
            let pair = await TranslationSupport.resolvePair(
                input: inputLocale.language,
                output: outputLanguage
            )
            switch await TranslationSupport.availability(from: pair.source, to: pair.target) {
            case .installed:
                break
            case .supported:
                state.statusMessage = t("status.model_missing")
                needsTranslationSetup = true
                return
            case .unsupported:
                state.statusMessage = t("status.unsupported_pair")
                return
            @unknown default:
                break
            }
        }

        state.reset()
        let pipeline = CaptionPipeline(state: state) { [weak self] in
            Task {
                await self?.stop()
            }
        }
        self.pipeline = pipeline
        overlay.show(state: state, settings: settings)
        overlay.setMovable(settings.isMovable)
        do {
            state.statusMessage = t("status.preparing")
            try await pipeline.start(
                inputLocale: inputLocale,
                outputLanguage: outputLanguage,
                translationEnabled: translationEnabled,
                correctionEnabled: correctionEnabled,
                contextualTerms: VocabularyStore.load()
            )
            state.statusMessage = nil
        } catch {
            state.statusMessage = "\(t("status.start_failed")): \(error.localizedDescription)"
            await pipeline.stop()
            overlay.hide()
            self.pipeline = nil
        }
    }

    func stop() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        await pipeline?.stop()
        pipeline = nil
        overlay.hide()
    }

    private func scheduleLanguageRestart() {
        // start 進行中 (モデル準備中等) の変更は isRunning がまだ false で
        // restartIfRunning が no-op になるため、start 完了後の再起動として繰り越す
        if isStarting {
            pendingLanguageRestart = true
            return
        }
        // 停止処理中の変更は次回 start が最新の言語設定を読むため何もしない
        guard !isBusy else { return }
        Task {
            await restartIfRunning()
        }
    }

    // start の全終了経路で繰り越しを消費する。早期 return 時 (isRunning false) は
    // 再起動せず破棄し、次回の正常 start 直後に無駄な stop→start が走るのを防ぐ
    private func consumePendingLanguageRestart() {
        guard pendingLanguageRestart else { return }
        pendingLanguageRestart = false
        guard state.isRunning else { return }
        Task {
            await restartIfRunning()
        }
    }

    private func restartIfRunning() async {
        guard state.isRunning else { return }
        await stop()
        await start()
    }
}
