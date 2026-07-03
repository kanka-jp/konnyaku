import AppKit
import Foundation
import Observation
import Translation

@MainActor
@Observable
final class AppController {
    let state = CaptionState()
    let settings: OverlaySettings
    let languages: LanguageSettings

    private let overlay = OverlayController()
    private var pipeline: CaptionPipeline?
    private(set) var isBusy = false
    // 非 nil の間、KonnyakuApp の translationTask がモデル DL を実行する
    private(set) var modelDownloadConfiguration: TranslationSession.Configuration?
    var isDownloadingModel: Bool { modelDownloadConfiguration != nil }
    private var isStarting = false
    private var pendingLanguageRestart = false
    // 繰り越し再起動が DL 待機状態の再計画 (start やり直し) まで行うか。DL 要否に
    // 影響しない設定は false で予約し、進行中 DL を捨てない
    private var pendingRestartReplansDownload = false

    var correctionEnabled: Bool {
        didSet {
            ConfigStore.set(String(correctionEnabled), forKey: ConfigStore.correctionKey)
        }
    }

    var preferLowLatencyTranslation: Bool {
        didSet {
            ConfigStore.set(String(preferLowLatencyTranslation), forKey: ConfigStore.lowLatencyKey)
        }
    }

    var realtimeTranslationEnabled: Bool {
        didSet {
            ConfigStore.set(String(realtimeTranslationEnabled), forKey: ConfigStore.realtimeTranslationKey)
        }
    }

    init() {
        // 手編集用の実体を初回起動時から用意する (メニュー変更を待たない)
        try? ConfigStore.ensureFileExists()
        try? VocabularyStore.ensureFileExists()
        let config = ConfigStore.load()
        settings = OverlaySettings(config: config)
        languages = LanguageSettings(config: config)
        correctionEnabled = config[ConfigStore.correctionKey] == "true"
        // 未設定 (初回) は速度優先を default にする (明示的な false のみ無効化)
        preferLowLatencyTranslation = config[ConfigStore.lowLatencyKey] != "false"
        realtimeTranslationEnabled = config[ConfigStore.realtimeTranslationKey] != "false"
    }

    func loadLanguages() async {
        await languages.loadAvailable()
    }

    func setCorrectionEnabled(_ enabled: Bool) {
        correctionEnabled = enabled
        scheduleLanguageRestart()
    }

    func setPreferLowLatencyTranslation(_ enabled: Bool) {
        preferLowLatencyTranslation = enabled
        scheduleLanguageRestart()
    }

    func setRealtimeTranslationEnabled(_ enabled: Bool) {
        realtimeTranslationEnabled = enabled
        // モデル DL 要否に影響しない設定のため replanDownload = false で予約する
        // (稼働中・start 進行中は再起動で反映、DL 待機のみの状態では進行中 DL を守り
        //  保存に留める — DL 完了後の自動 start が最新値を読む)
        scheduleLanguageRestart(replanDownload: false)
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

    // KonnyakuApp の translationTask (prepareTranslation 実行元) から結果を受け取る。
    // DL 中の設定変更で configuration が差し替わった後に旧 task の完了が届くことが
    // あるため、発火時の configuration と現在値の一致を guard する (stale 上書き防止)
    func modelDownloadSucceeded(for configuration: TranslationSession.Configuration?) {
        guard configuration == modelDownloadConfiguration else { return }
        debugLog("model download done, auto-starting captions")
        modelDownloadConfiguration = nil
        state.statusMessage = nil
        // nil 代入は translationTask (この通知の呼び出し元) 自身を cancel するため、
        // 自動開始はその cancel を継承しない独立 Task で行う
        Task {
            await start()
        }
    }

    func modelDownloadFailed(_ error: Error, for configuration: TranslationSession.Configuration?) {
        guard configuration == modelDownloadConfiguration else { return }
        debugLog("model download failed: \(error)")
        modelDownloadConfiguration = nil
        state.statusMessage = "\(t("status.model_download_failed")): \(error.localizedDescription)"
    }

    func cancelModelDownload() {
        debugLog("model download cancelled by user")
        modelDownloadConfiguration = nil
        state.statusMessage = nil
    }

    func toggle() async {
        if state.isRunning {
            await stop()
        } else if isDownloadingModel {
            // DL 中の再押下は中止として扱う (再開扱いで進捗を捨てる誤操作を防ぐ)
            cancelModelDownload()
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
        // 開始し直すたびに最新の言語・strategy 設定で DL 要否を再判定する
        modelDownloadConfiguration = nil

        // start 全体で同じ設定を使う (途中の変更は pendingLanguageRestart 経由の
        // 再起動で反映し、チェック済み設定と起動設定の食い違いを防ぐ)
        let inputLocale = languages.inputLocale
        let outputLanguage = languages.outputLanguage
        let translationEnabled = languages.isTranslationEnabled
        let correctionEnabled = self.correctionEnabled
        let realtimeTranslationEnabled = self.realtimeTranslationEnabled

        guard await AudioCaptureEngine.requestMicrophoneAccess() else {
            state.statusMessage = t("status.mic_denied")
            return
        }

        var useLowLatencyTranslation = false
        if translationEnabled {
            // 実翻訳セッション (CaptionPipeline の worker) と同じ resolvePair 済みペアで
            // 可用性を判定し、チェック対象とセッション対象の不一致を防ぐ
            let pair = await TranslationSupport.resolvePair(
                input: inputLocale.language,
                output: outputLanguage
            )
            let plan = await TranslationSupport.plan(
                from: pair.source,
                to: pair.target,
                preferLowLatency: preferLowLatencyTranslation
            )
            useLowLatencyTranslation = plan.usesLowLatency
            switch plan.status {
            case .installed:
                break
            case .supported:
                // popup を挟まず自動 DL に入る。進捗はメニューバーアイコンと
                // status 文言で表現し、完了後は modelDownloadSucceeded が自動開始する
                debugLog("model not installed, scheduling auto-download (lowLatency: \(plan.usesLowLatency))")
                state.statusMessage = t("status.model_downloading")
                var configuration = TranslationSupport.makeSetupConfiguration(
                    source: pair.source,
                    target: pair.target,
                    lowLatency: plan.usesLowLatency
                )
                // 失敗後の再試行等で前回と同値の configuration は translationTask が
                // 再発火しないため、version を進めて常に新しい値として扱わせる
                configuration.invalidate()
                modelDownloadConfiguration = configuration
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
                useLowLatencyTranslation: useLowLatencyTranslation,
                volatileTranslationEnabled: realtimeTranslationEnabled,
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

    private func scheduleLanguageRestart(replanDownload: Bool = true) {
        // start 進行中 (モデル準備中等) の変更は isRunning がまだ false で
        // restartIfRunning が no-op になるため、start 完了後の再起動として繰り越す
        if isStarting {
            pendingLanguageRestart = true
            if replanDownload {
                pendingRestartReplansDownload = true
            }
            return
        }
        // 停止処理中の変更は次回 start が最新の言語設定を読むため何もしない
        guard !isBusy else { return }
        Task {
            await restartIfRunning(replanDownload: replanDownload)
        }
    }

    // start の全終了経路で繰り越しを消費する。実行可否は restartIfRunning に一本化する
    // (稼働中は新設定でやり直し、DL 中のやり直しは replanDownload に従い、mic 拒否等の
    //  素の早期 return では何もしない)
    private func consumePendingLanguageRestart() {
        guard pendingLanguageRestart else { return }
        pendingLanguageRestart = false
        let replanDownload = pendingRestartReplansDownload
        pendingRestartReplansDownload = false
        Task {
            await restartIfRunning(replanDownload: replanDownload)
        }
    }

    private func restartIfRunning(replanDownload: Bool = true) async {
        if state.isRunning {
            await stop()
            await start()
            return
        }
        // モデル DL 中の言語・strategy 変更は、旧設定のアセットを待たず新設定で
        // DL からやり直す (start 冒頭の configuration クリアが旧 task を cancel する)。
        // DL 要否に影響しない設定 (replanDownload = false) ではやり直さない
        if isDownloadingModel && replanDownload {
            await start()
        }
    }
}
