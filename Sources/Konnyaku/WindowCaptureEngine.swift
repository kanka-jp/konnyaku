import AVFoundation
@preconcurrency import ScreenCaptureKit

// 共有元の選択に SCContentSharingPicker を使う: ピッカーでの選択自体がユーザー同意に
// なるため画面収録の TCC 許可が不要 (自前のウィンドウ一覧 UI も不要)
@MainActor
final class WindowCaptureEngine: NSObject {
    var onSelection: ((SCContentFilter) -> Void)?
    var onStopped: ((String) -> Void)?
    // 共有ビュー側で window の縦横比を合わせ直すための通知
    var onSourceSizeChanged: ((CGSize) -> Void)?

    private var stream: SCStream?
    private var sink: CaptureFrameSink?
    private var isObserverRegistered = false
    private let sampleQueue = DispatchQueue(label: "jp.kanka.konnyaku.capture")
    private var lastRequestedPixelSize = CGSize.zero
    // startCapture / stop のたびに進める世代番号。await 中に開始・停止が重なった場合や
    // 置き換え済み旧 stream からの遅延イベントを stale として無効化する (旧 stream の
    // 孤児化・現行状態の誤破棄の防止)
    private var captureGeneration = 0
    private var consecutiveConfigUpdateFailures = 0

    nonisolated static let framesPerSecond: CMTimeScale = 30
    // SCK が受け付ける実用上限で config サイズを抑える (異常値でのストリーム失敗防止)
    nonisolated static let maxStreamDimension: CGFloat = 4096
    nonisolated static let minStreamDimension: CGFloat = 64
    // updateConfiguration が連続で失敗し続ける環境での 30fps リトライ暴走を打ち切る上限
    nonisolated static let maxConsecutiveConfigUpdateFailures = 3
    // SCStreamConfiguration.backgroundColor は unowned(unsafe) のため、一時オブジェクトを
    // 渡すと即解放される。寿命を static で保証する
    private nonisolated static let streamBackgroundColor = CGColor(gray: 0, alpha: 1)

    func presentPicker() {
        let picker = SCContentSharingPicker.shared
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleWindow]
        // 共有ビュー自身を選ぶと映像の無限ミラーになるため自アプリを除外する
        if let bundleID = Bundle.main.bundleIdentifier {
            configuration.excludedBundleIDs = [bundleID]
        }
        picker.defaultConfiguration = configuration
        if !isObserverRegistered {
            picker.add(self)
            isObserverRegistered = true
        }
        picker.isActive = true
        picker.present()
    }

    func startCapture(with filter: SCContentFilter, renderer: AVSampleBufferVideoRenderer) async {
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
        let pixelSize = Self.streamPixelSize(
            contentSizePoints: filter.contentRect.size,
            pointPixelScale: CGFloat(filter.pointPixelScale)
        )
        lastRequestedPixelSize = pixelSize
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

    func stop() async {
        captureGeneration += 1
        SCContentSharingPicker.shared.isActive = false
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
        Task {
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

    // 上限は縦横比を保って縮める (縦横独立に clamp すると config とコンテンツの縦横比が
    // ずれ、SCK のアスペクト維持描画で余白が常設化する)
    nonisolated static func clampedPixelSize(_ size: CGSize) -> CGSize {
        var width = size.width.rounded()
        var height = size.height.rounded()
        let overshoot = max(width / maxStreamDimension, height / maxStreamDimension)
        if overshoot > 1 {
            width = (width / overshoot).rounded()
            height = (height / overshoot).rounded()
        }
        return CGSize(
            width: max(width, minStreamDimension),
            height: max(height, minStreamDimension)
        )
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

extension WindowCaptureEngine: SCContentSharingPickerObserver {
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        // キャンセルは何もしない (既存のキャプチャ・共有ビューを維持する)
    }

    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?
    ) {
        nonisolated(unsafe) let filter = filter
        Task { @MainActor in
            self.onSelection?(filter)
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        Task { @MainActor in
            self.onStopped?("\(t("shareview.picker_failed")): \(error.localizedDescription)")
        }
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
