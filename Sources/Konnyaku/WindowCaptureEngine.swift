import AVFoundation
@preconcurrency import ScreenCaptureKit

// 共有元の選択は SCShareableContent のウィンドウ一覧 + アプリ内 UI で行う (画面収録の
// TCC 許可が必要)。TCC 不要のシステム標準ピッカー (SCContentSharingPicker) は、常駐
// キャプチャ (DisplayLink 等) を含む環境で「共有」の確定が機能しないケースが実機で
// 確認されたため採用しない
@MainActor
final class WindowCaptureEngine: NSObject {
    var onStopped: ((String) -> Void)?
    // 共有ビュー側で window の縦横比を合わせ直すための通知
    var onSourceSizeChanged: ((CGSize) -> Void)?

    private var stream: SCStream?
    private var sink: CaptureFrameSink?
    private let sampleQueue = DispatchQueue(label: "jp.kanka.konnyaku.capture")
    private var lastRequestedPixelSize = CGSize.zero
    // startCapture / stop のたびに進める世代番号。await 中に開始・停止が重なった場合や
    // 置き換え済み旧 stream からの遅延イベントを stale として無効化する (旧 stream の
    // 孤児化・現行状態の誤破棄の防止)
    private var captureGeneration = 0
    private var consecutiveConfigUpdateFailures = 0
    private var configUpdateTask: Task<Void, Never>?

    nonisolated static let framesPerSecond: CMTimeScale = 30
    // SCK が受け付ける実用上限で config サイズを抑える (異常値でのストリーム失敗防止)
    nonisolated static let maxStreamDimension: CGFloat = 4096
    nonisolated static let minStreamDimension: CGFloat = 64
    // updateConfiguration が連続で失敗し続ける環境での 30fps リトライ暴走を打ち切る上限
    nonisolated static let maxConsecutiveConfigUpdateFailures = 3
    // SCStreamConfiguration.backgroundColor は unowned(unsafe) のため、一時オブジェクトを
    // 渡すと即解放される。寿命を static で保証する
    private nonisolated static let streamBackgroundColor = CGColor(gray: 0, alpha: 1)

    struct ShareableWindow: Identifiable, Equatable, Sendable {
        let id: CGWindowID
        let title: String
        let appName: String
        let thumbnail: CGImage?

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.id == rhs.id && lhs.title == rhs.title && lhs.appName == rhs.appName
                && lhs.thumbnail === rhs.thumbnail
        }
    }

    // 画面収録の TCC 許可。request は未許可時に一度だけシステムダイアログを出すが、
    // ダイアログでの許可はアプリ再起動後に反映される (macOS の画面収録 TCC の仕様)
    nonisolated static func preflightScreenCaptureAccess() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    nonisolated static func requestScreenCaptureAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    func loadShareableWindows() async throws -> [ShareableWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: true)
        let ownBundleID = Bundle.main.bundleIdentifier
        let candidates = content.windows.filter { window in
            Self.isShareable(
                title: window.title,
                ownerBundleID: window.owningApplication?.bundleIdentifier,
                ownBundleID: ownBundleID,
                frame: window.frame,
                layer: window.windowLayer
            )
        }
        var windows: [ShareableWindow] = []
        for window in candidates {
            windows.append(ShareableWindow(
                id: window.windowID,
                title: window.title ?? "",
                appName: window.owningApplication?.applicationName ?? "",
                thumbnail: await Self.thumbnail(of: window)
            ))
        }
        return windows.sorted { ($0.appName, $0.title) < ($1.appName, $1.title) }
    }

    // 一覧表示用の静止画。失敗はプレースホルダー表示に落とすだけなので握りつぶす
    private static func thumbnail(of window: SCWindow) async -> CGImage? {
        let configuration = SCStreamConfiguration()
        let aspect = max(window.frame.height, 1) / max(window.frame.width, 1)
        let size = clampedPixelSize(CGSize(width: 480, height: 480 * aspect))
        configuration.width = Int(size.width)
        configuration.height = Int(size.height)
        configuration.showsCursor = false
        return try? await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: window),
            configuration: configuration
        )
    }

    // メニューバー項目等の非通常レイヤー・タイトル無し・極小ウィンドウ・自アプリ
    // (共有ビュー自身を選ぶと映像の無限ミラーになる) を一覧から除外する
    nonisolated static func isShareable(
        title: String?, ownerBundleID: String?, ownBundleID: String?, frame: CGRect, layer: Int
    ) -> Bool {
        guard let title, !title.isEmpty else { return false }
        guard layer == 0 else { return false }
        guard frame.width >= 64, frame.height >= 64 else { return false }
        if let ownBundleID, ownerBundleID == ownBundleID { return false }
        return true
    }

    func startCapture(windowID: CGWindowID, renderer: AVSampleBufferVideoRenderer) async {
        captureGeneration += 1
        let generation = captureGeneration
        consecutiveConfigUpdateFailures = 0
        // 共有元の選び直しはストリームを作り直す (サイズ・フレーム状態のリセットを新規
        // ストリームに一本化する)
        if let oldStream = stream {
            stream = nil
            sink = nil
            try? await oldStream.stopCapture()
        }
        // windowID は一覧表示からの経過で消えていることがあるため、開始時点で解決し直す。
        // 一覧 (loadShareableWindows) と違い onScreenWindowsOnly: false で引く — 確定までに
        // 最小化・別 Space へ移動されても選択は有効で、SCK はどちらもキャプチャできる
        let window: SCWindow
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: false)
            guard let found = content.windows.first(where: { $0.windowID == windowID }) else {
                if generation == captureGeneration {
                    onStopped?(t("shareview.source_ended"))
                }
                return
            }
            window = found
        } catch {
            debugLog("shareable content failed: \(error)")
            if generation == captureGeneration {
                onStopped?("\(t("shareview.capture_failed")): \(error.localizedDescription)")
            }
            return
        }
        guard generation == captureGeneration else { return }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let pixelSize = Self.streamPixelSize(
            contentSizePoints: filter.contentRect.size,
            pointPixelScale: CGFloat(filter.pointPixelScale)
        )
        lastRequestedPixelSize = pixelSize
        debugLog(
            "capture start: contentRect=\(filter.contentRect) scale=\(filter.pointPixelScale) config=\(pixelSize)"
        )
        onSourceSizeChanged?(pixelSize)
        let sink = CaptureFrameSink(renderer: renderer) { [weak self] desired in
            Task { @MainActor in self?.followSourceResize(toPixelSize: desired, generation: generation) }
        } onStopped: { [weak self] error in
            Task { @MainActor in self?.handleStreamStopped(error, generation: generation) }
        }
        let stream = SCStream(filter: filter, configuration: Self.makeConfiguration(pixelSize: pixelSize), delegate: sink)
        do {
            try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sampleQueue)
            try await stream.startCapture()
        } catch {
            debugLog("capture start failed: \(error)")
            if generation == captureGeneration {
                onStopped?("\(t("shareview.capture_failed")): \(error.localizedDescription)")
            }
            return
        }
        // await 中に別の開始・停止が走っていたら据えずに畳む (孤児ストリーム防止)
        guard generation == captureGeneration else {
            try? await stream.stopCapture()
            return
        }
        self.sink = sink
        self.stream = stream
    }

    // 同期的に世代を進めて queued 済みイベントを即 stale 化する (stop() は async のため、
    // close 直後の再オープンまでに世代が進まず旧イベントが新セッションへ届く隙間がある)
    func invalidate() {
        captureGeneration += 1
    }

    func stop() async {
        captureGeneration += 1
        guard let stream else { return }
        self.stream = nil
        sink = nil
        try? await stream.stopCapture()
    }

    private static func makeConfiguration(pixelSize: CGSize) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = Int(pixelSize.width)
        configuration.height = Int(pixelSize.height)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: framesPerSecond)
        configuration.showsCursor = true
        // リサイズ追従が反映されるまでの縦横比の食い違いで生じる余白を黒で埋める
        configuration.backgroundColor = streamBackgroundColor
        return configuration
    }

    // 共有元ウィンドウのリサイズで native サイズと config が乖離したら作り直さず
    // updateConfiguration で追従する (バッファサイズが変わり余白・解像度劣化が解消される)
    private func followSourceResize(toPixelSize desired: CGSize, generation: Int) {
        guard generation == captureGeneration, let stream,
              desired != lastRequestedPixelSize else { return }
        lastRequestedPixelSize = desired
        onSourceSizeChanged?(desired)
        let previous = configUpdateTask
        configUpdateTask = Task {
            // 連続リサイズで複数の更新が並行すると完了順序の逆転で古いサイズが最終適用され
            // うるため、先行更新を待って直列化し、最新要求でなくなった更新は破棄する
            await previous?.value
            guard generation == captureGeneration,
                  desired == lastRequestedPixelSize else { return }
            do {
                try await stream.updateConfiguration(Self.makeConfiguration(pixelSize: desired))
                consecutiveConfigUpdateFailures = 0
            } catch {
                debugLog("updateConfiguration failed: \(error)")
                // dedup 状態 (lastRequested / sink の lastNotified) が進んだままだと追従が
                // 恒久停止するため巻き戻し、次フレームの通知で再試行させる (上限つき)
                guard generation == captureGeneration else { return }
                consecutiveConfigUpdateFailures += 1
                if consecutiveConfigUpdateFailures < Self.maxConsecutiveConfigUpdateFailures {
                    lastRequestedPixelSize = .zero
                    sampleQueue.async { [weak sink = self.sink] in
                        sink?.resetNotifiedSize()
                    }
                }
            }
        }
    }

    private func handleStreamStopped(_ error: Error, generation: Int) {
        // stop() 起点 (ユーザーが共有ビューを閉じた) の停止と、置き換え済み旧 stream の
        // 遅延エラーは通知しない (後者は現行キャプチャの状態を誤って破棄するため)
        guard generation == captureGeneration, stream != nil else { return }
        debugLog("capture stream stopped: \(error)")
        stream = nil
        sink = nil
        onStopped?(t("shareview.source_ended"))
    }

    nonisolated static func streamPixelSize(contentSizePoints: CGSize, pointPixelScale: CGFloat) -> CGSize {
        clampedPixelSize(CGSize(
            width: contentSizePoints.width * pointPixelScale,
            height: contentSizePoints.height * pointPixelScale
        ))
    }

    // 上限・下限とも縦横比を保って収める (縦横独立に clamp すると config とコンテンツの
    // 縦横比がずれ、SCK のアスペクト維持描画で余白が常設化する)。縦横比が 64:1 を超える
    // 病的なウィンドウのみ、上限優先の結果として短辺が下限を割ることを許容する
    nonisolated static func clampedPixelSize(_ size: CGSize) -> CGSize {
        var width = max(size.width.rounded(), 1)
        var height = max(size.height.rounded(), 1)
        let undershoot = max(minStreamDimension / width, minStreamDimension / height)
        if undershoot > 1 {
            width = (width * undershoot).rounded()
            height = (height * undershoot).rounded()
        }
        let overshoot = max(width / maxStreamDimension, height / maxStreamDimension)
        if overshoot > 1 {
            width = (width / overshoot).rounded()
            height = (height / overshoot).rounded()
        }
        return CGSize(width: width, height: height)
    }

    // SCStream.h の定義: contentRect = surface 内の描画先 (pt)、contentScale = 描画
    // サイズ / 原寸、scaleFactor = pixel/pt。この 3 つから共有元の原寸 px を復元できる
    nonisolated static func nativePixelSize(
        contentRect: CGRect, contentScale: CGFloat, scaleFactor: CGFloat
    ) -> CGSize? {
        guard contentScale > 0.01, scaleFactor > 0.01,
              contentRect.width > 1, contentRect.height > 1 else { return nil }
        return clampedPixelSize(CGSize(
            width: contentRect.width / contentScale * scaleFactor,
            height: contentRect.height / contentScale * scaleFactor
        ))
    }

    // 丸め誤差レベルの乖離では追従しない (updateConfiguration の往復を避ける)
    nonisolated static func shouldFollowResize(
        native: CGSize, bufferSize: CGSize, tolerance: CGFloat = 8
    ) -> Bool {
        abs(native.width - bufferSize.width) > tolerance
            || abs(native.height - bufferSize.height) > tolerance
    }
}

// SCStream の出力・停止通知はバックグラウンド queue に届く。AVSampleBufferVideoRenderer
// の enqueue は AVQueuedSampleBufferRendering としてスレッド安全のため直接流し、MainActor
// へは低頻度イベント (サイズ追従・停止) のみ hop する
private final class CaptureFrameSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let renderer: AVSampleBufferVideoRenderer
    private let onDesiredSizeChange: @Sendable (CGSize) -> Void
    private let onStopped: @Sendable (Error) -> Void
    // sampleHandlerQueue (直列) 上でのみ読み書きする
    private var lastNotifiedSize = CGSize.zero

    // sampleHandlerQueue 上で呼ぶこと (didOutputSampleBuffer と同じ直列文脈)
    func resetNotifiedSize() {
        lastNotifiedSize = .zero
    }

    init(
        renderer: AVSampleBufferVideoRenderer,
        onDesiredSizeChange: @escaping @Sendable (CGSize) -> Void,
        onStopped: @escaping @Sendable (Error) -> Void
    ) {
        self.renderer = renderer
        self.onDesiredSizeChange = onDesiredSizeChange
        self.onStopped = onStopped
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]])?.first,
              let statusValue = attachments[.status] as? Int,
              SCFrameStatus(rawValue: statusValue) == .complete
        else { return }
        if renderer.status == .failed {
            renderer.flush()
        }
        if renderer.isReadyForMoreMediaData {
            // キャプチャフレームの PTS はホスト時計基準で、timebase 未設定の renderer では
            // スケジュールされないため即時表示を指定する (attachments array の要素は
            // CFMutableDictionary — CMSampleBufferGetSampleAttachmentsArray の契約)
            if let dicts = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true)
                as? [NSMutableDictionary],
                let first = dicts.first
            {
                first[kCMSampleAttachmentKey_DisplayImmediately as NSString] = true
            }
            renderer.enqueue(sampleBuffer)
        }
        notifyIfSourceResized(attachments: attachments, sampleBuffer: sampleBuffer)
    }

    private func notifyIfSourceResized(attachments: [SCStreamFrameInfo: Any], sampleBuffer: CMSampleBuffer) {
        guard let contentScale = attachments[.contentScale] as? CGFloat,
              let scaleFactor = attachments[.scaleFactor] as? CGFloat,
              let rectDict = attachments[.contentRect] as? NSDictionary,
              let contentRect = CGRect(dictionaryRepresentation: rectDict as CFDictionary),
              let pixelBuffer = sampleBuffer.imageBuffer
        else { return }
        let bufferSize = CGSize(
            width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer)
        )
        guard let native = WindowCaptureEngine.nativePixelSize(
            contentRect: contentRect, contentScale: contentScale, scaleFactor: scaleFactor
        ),
            WindowCaptureEngine.shouldFollowResize(native: native, bufferSize: bufferSize),
            native != lastNotifiedSize
        else { return }
        lastNotifiedSize = native
        onDesiredSizeChange(native)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStopped(error)
    }
}
