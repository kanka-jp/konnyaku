import AppKit
import Foundation
import Observation
import SwiftUI
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
    // 非 nil の間、ModelDownloadView の translationTask がモデル DL を実行する
    private(set) var modelDownloadConfiguration: TranslationSession.Configuration?
    var isDownloadingModel: Bool { modelDownloadConfiguration != nil }
    // prepareTranslation は進捗 % を公開しないため、経過時間の更新で「進行中」を可視化する
    private(set) var modelDownloadElapsedText: String?
    // 音声認識モデル DL 中のみ非 nil (AssetInventory の実 Progress、window が determinate 表示)
    private(set) var speechModelDownloadProgress: Progress?
    // 中止の判定はエラー型でなく本フラグを SoT にする (progress.cancel() で
    // downloadAndInstall が投げる cancel エラーの型は文書化されていないため)
    private var speechModelDownloadCancelledByUser = false
    private var modelDownloadStartedAt: Date?
    private var modelDownloadTicker: Task<Void, Never>?
    private var modelDownloadWindow: NSWindow?
    // prepareTranslation が成功を返してもアセットが installed にならない環境があり、
    // 成功後の自動再開が同一 DL を無限に繰り返す (実測ループ)。成功済みの DL キーを
    // 覚えておき、自動再開の再スケジュールだけを遮断する (ユーザー起点の開始は許可)
    private var pendingDownloadKey: String?
    private var completedDownloadKey: String?
    private var isStarting = false
    private var didAttemptAutoStart = false
    private var pendingLanguageRestart = false
    // 稼働中の worker 差し替えは preferLowLatencyTranslation でなく直近 start() が解決した
    // strategy を使う (plan() のフォールバックとの食い違い防止)
    private var activeUseLowLatencyTranslation = false
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

    var autoStartEnabled: Bool {
        didSet {
            ConfigStore.set(String(autoStartEnabled), forKey: ConfigStore.autoStartKey)
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
        autoStartEnabled = config[ConfigStore.autoStartKey] != "false"
    }

    // メニューバー label の .task (起動時に必ず一度現れる唯一の view) から呼ばれる。
    // label の再評価で .task が再発火しても開始し直さないよう one-shot にする
    func autoStartIfEnabled() {
        guard !didAttemptAutoStart else { return }
        didAttemptAutoStart = true
        guard autoStartEnabled else { return }
        // start() が .task の cancel を継承すると DL 中断後に didAttemptAutoStart で
        // 再試行も塞がれるため、独立 Task で開始する (modelDownloadSucceeded と同じ)
        Task { await start() }
    }

    func loadLanguages() async {
        await languages.loadAvailable()
    }

    // 稼働中は worker だけ差し替え全体再起動を避ける (体感の途切れ・prepareTranslation
    // 再実行の防止)。非稼働中・start/stop 進行中 (isBusy) は値の保存のみ
    func setCorrectionEnabled(_ enabled: Bool) {
        correctionEnabled = enabled
        guard state.isRunning, !isBusy, let pipeline else { return }
        pipeline.updateCorrectionEnabled(
            enabled, inputLocale: languages.inputLocale, vocabulary: VocabularyStore.load())
    }

    func setPreferLowLatencyTranslation(_ enabled: Bool) {
        preferLowLatencyTranslation = enabled
        // 言語・strategy の変更はユーザー起点のため、ループ遮断キーをリセットして
        // 新設定での DL 再試行を許可する (toggle と同じ契約。scheduleLanguageRestart
        // 側でクリアすると correction 変更や succeeded 直後の自動 start と競合する
        // 割り込みでも消えてしまい、遮断をすり抜ける)
        completedDownloadKey = nil
        scheduleLanguageRestart()
    }

    // 稼働中はパイプライン全体を再起動せず追従訳 worker だけ差し替える。非稼働中は
    // 値の保存のみで、次回 start() が読む。start/stop 進行中 (isBusy) は何もしない
    func setRealtimeTranslationEnabled(_ enabled: Bool) {
        realtimeTranslationEnabled = enabled
        guard state.isRunning, !isBusy, let pipeline else { return }
        pipeline.updateVolatileTranslationEnabled(
            enabled,
            inputLanguage: languages.inputLocale.language,
            outputLanguage: languages.outputLanguage,
            lowLatency: activeUseLowLatencyTranslation
        )
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
        completedDownloadKey = nil
        scheduleLanguageRestart()
    }

    func setOutputLanguage(_ identifier: String) {
        languages.outputLanguageIdentifier = identifier
        completedDownloadKey = nil
        scheduleLanguageRestart()
    }

    // ModelDownloadView の translationTask (prepareTranslation 実行元) から結果を受け取る。
    // DL 中の設定変更で configuration が差し替わった後に旧 task の完了が届くことが
    // あるため、発火時の configuration と現在値の一致を guard する (stale 上書き防止)
    func modelDownloadSucceeded(for configuration: TranslationSession.Configuration?) {
        guard configuration == modelDownloadConfiguration else { return }
        debugLog("model download done, auto-starting captions")
        modelDownloadConfiguration = nil
        completedDownloadKey = pendingDownloadKey
        pendingDownloadKey = nil
        endModelDownloadProgress()
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
        pendingDownloadKey = nil
        endModelDownloadProgress()
        state.statusMessage = "\(t("status.model_download_failed")): \(error.localizedDescription)"
        // DL の主 UI (セットアップウィンドウ) が黙って消えると失敗理由がメニューを
        // 開くまで見えないため、alert で明示する
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = t("status.model_download_failed")
        alert.informativeText = error.localizedDescription
        NSApp.activate()
        alert.runModal()
    }

    func cancelModelDownload() {
        debugLog("model download cancelled by user")
        modelDownloadConfiguration = nil
        pendingDownloadKey = nil
        endModelDownloadProgress()
        state.statusMessage = nil
    }

    // アプリ起点の自動 DL は停滞しうる (LSUIElement で承認ダイアログが埋もれる /
    // background 優先度) ため、確実に進む手動 DL (進捗バー付き) への導線を出す
    func openTranslationLanguageSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")
        else { return }
        NSWorkspace.shared.open(url)
    }

    private func beginModelDownloadProgress(
        source: Locale.Language, target: Locale.Language, lowLatency: Bool
    ) {
        modelDownloadStartedAt = Date()
        refreshModelDownloadElapsed()
        modelDownloadTicker?.cancel()
        let configuration = modelDownloadConfiguration
        modelDownloadTicker = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.refreshModelDownloadElapsed()
                // システム設定からの手動 DL で完了した場合 prepareTranslation が解決しない
                // ことがあるため、installed への遷移を polling で検知して自動開始につなぐ
                tick += 1
                if tick % 5 == 0,
                    await TranslationSupport.isInstalled(
                        source: source, target: target, lowLatency: lowLatency)
                {
                    debugLog("model install detected via availability polling")
                    self.modelDownloadSucceeded(for: configuration)
                    return
                }
            }
        }
        showModelDownloadWindow()
    }

    private func endModelDownloadProgress() {
        modelDownloadTicker?.cancel()
        modelDownloadTicker = nil
        modelDownloadStartedAt = nil
        modelDownloadElapsedText = nil
        // ウィンドウは使い捨てて次回 DL で作り直す (orderOut で温存すると view 階層が
        // 常駐し続けるうえ、非表示ウィンドウ上での translationTask 再発火が未検証経路になる)
        modelDownloadWindow?.close()
        modelDownloadWindow = nil
    }

    private func showModelDownloadWindow() {
        showDownloadWindow(
            title: t("window.model_download_title"),
            rootView: AnyView(ModelDownloadView(controller: self)))
    }

    private func showDownloadWindow(title: String, rootView: AnyView) {
        // 呼び出しごとに作り直す (既存 window の再利用だと title/rootView 引数が無視され
        // 別フローの内容が残る罠になる。全 DL 終了経路が close+nil で破棄する設計とも一致)
        modelDownloadWindow?.close()
        let window = NSWindow(
            contentViewController: NSHostingController(rootView: rootView))
        window.title = title
        // 閉じるボタンは付けない (閉じる = 中止をウィンドウ内の中止ボタンに一本化し、
        // 「閉じただけで DL 承認フローが死ぬ」誤操作を防ぐ)
        window.styleMask = [.titled]
        // overlay (OverlayController) と同じく Space 切替に追従させる
        // (承認シートごと元の Space に取り残されて「進まない」体験が再発するのを防ぐ)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // macOS 14+ の activate() は cooperative で前面化が保証されないため、
        // 承認シートの可視性を activation の成否に依存させない
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.center()
        modelDownloadWindow = window
        window.makeKeyAndOrderFront(nil)
        // LSUIElement app は自動で前面にならず、承認シートが背後に埋もれるため明示 activate
        NSApp.activate()
    }

    private func beginSpeechModelDownload(_ progress: Progress) {
        speechModelDownloadProgress = progress
        state.statusMessage = t("status.speech_model_downloading")
        showDownloadWindow(
            title: t("window.speech_model_download_title"),
            rootView: AnyView(SpeechModelDownloadView(controller: self)))
    }

    private func endSpeechModelDownload() {
        guard speechModelDownloadProgress != nil else { return }
        speechModelDownloadProgress = nil
        // DL 完了後も pipeline 起動 (analyzer / audio / worker) は続くため準備中へ戻す
        // (失敗・成功の最終文言は start() の do/catch が上書きする)
        state.statusMessage = t("status.preparing")
        modelDownloadWindow?.close()
        modelDownloadWindow = nil
    }

    func cancelSpeechModelDownload() {
        debugLog("speech model download cancelled by user")
        // cancel は downloadAndInstall を失敗させ、start() の catch が後始末する
        speechModelDownloadCancelledByUser = true
        speechModelDownloadProgress?.cancel()
    }

    private func refreshModelDownloadElapsed() {
        guard let startedAt = modelDownloadStartedAt else { return }
        let seconds = max(0, Int(Date().timeIntervalSince(startedAt)))
        modelDownloadElapsedText = Duration.seconds(seconds).formatted(
            .time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }

    func toggle() async {
        if state.isRunning {
            await stop()
        } else if isDownloadingModel {
            // DL 中の再押下は中止として扱う (再開扱いで進捗を捨てる誤操作を防ぐ)
            cancelModelDownload()
        } else {
            // ユーザー起点の開始はループ遮断の対象外にして明示リトライを常に許可する
            completedDownloadKey = nil
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
        endModelDownloadProgress()

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
        // translationEnabled が false の間は未使用 (CaptionPipeline.start に渡すだけで
        // 参照されない)。resolvePair は非同期呼び出しのため、翻訳無効時は省略する
        var resolvedPair: (source: Locale.Language, target: Locale.Language) =
            (inputLocale.language, outputLanguage)
        if translationEnabled {
            // 実翻訳セッション (CaptionPipeline の worker) と同じ resolvePair 済みペアで
            // 可用性を判定し、チェック対象とセッション対象の不一致を防ぐ。CaptionPipeline
            // 側にもこのペアをそのまま渡し、worker 内での再解決 (3 重呼び出し) を避ける
            let pair = await TranslationSupport.resolvePair(
                input: inputLocale.language,
                output: outputLanguage
            )
            resolvedPair = pair
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
                let downloadKey =
                    "\(pair.source.maximalIdentifier)->\(pair.target.maximalIdentifier)|\(plan.usesLowLatency)"
                if downloadKey == completedDownloadKey {
                    // 成功報告済みの DL なのに installed に遷移していない。再スケジュール
                    // しても同じ結果の無限ループになるため、ここで止めて手動 DL へ誘導する
                    debugLog("download loop breaker fired: \(downloadKey)")
                    state.statusMessage = t("status.model_download_incomplete")
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = t("alert.model_unavailable_title")
                    alert.informativeText = t("status.model_download_incomplete")
                    // メニューの手動 DL ボタンは DL 中しか出ないため、案内先への導線を
                    // alert 自身に持たせる
                    alert.addButton(withTitle: t("alert.open_settings"))
                    alert.addButton(withTitle: t("alert.close"))
                    NSApp.activate()
                    if alert.runModal() == .alertFirstButtonReturn {
                        openTranslationLanguageSettings()
                    }
                    return
                }
                // popup を挟まず自動 DL に入る。DL 中の表示は MenuContent が
                // isDownloadingModel から組み立て、完了後は modelDownloadSucceeded が自動開始する
                debugLog("model not installed, scheduling auto-download (lowLatency: \(plan.usesLowLatency))")
                var configuration = TranslationSupport.makeSetupConfiguration(
                    source: pair.source,
                    target: pair.target,
                    lowLatency: plan.usesLowLatency
                )
                // 失敗後の再試行等で前回と同値の configuration は translationTask が
                // 再発火しないため、version を進めて常に新しい値として扱わせる
                configuration.invalidate()
                modelDownloadConfiguration = configuration
                pendingDownloadKey = downloadKey
                beginModelDownloadProgress(
                    source: pair.source, target: pair.target, lowLatency: plan.usesLowLatency)
                return
            case .unsupported:
                state.statusMessage = t("status.unsupported_pair")
                return
            @unknown default:
                break
            }
        }
        activeUseLowLatencyTranslation = useLowLatencyTranslation

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
            speechModelDownloadCancelledByUser = false
            try await pipeline.start(
                inputLocale: inputLocale,
                outputLanguage: outputLanguage,
                translationEnabled: translationEnabled,
                useLowLatencyTranslation: useLowLatencyTranslation,
                volatileTranslationEnabled: realtimeTranslationEnabled,
                correctionEnabled: correctionEnabled,
                contextualTerms: VocabularyStore.load(),
                resolvedSource: resolvedPair.source,
                resolvedTarget: resolvedPair.target,
                onSpeechModelDownload: { [weak self] progress in
                    if let progress {
                        self?.beginSpeechModelDownload(progress)
                    } else {
                        self?.endSpeechModelDownload()
                    }
                }
            )
            endSpeechModelDownload()
            state.statusMessage = nil
        } catch {
            endSpeechModelDownload()
            // 音声モデル DL の中止はユーザー操作のためエラー表示しない
            if error is CancellationError || speechModelDownloadCancelledByUser {
                state.statusMessage = nil
            } else {
                state.statusMessage = "\(t("status.start_failed")): \(error.localizedDescription)"
            }
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
