import AVFoundation
import Speech

@MainActor
final class AudioCaptureEngine {
    private let engine = AVAudioEngine()

    static func requestMicrophoneAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func start(
        convertingTo analyzerFormat: AVAudioFormat,
        onBuffer: @escaping @Sendable (AnalyzerInput) -> Void
    ) throws {
        let input = engine.inputNode
        let micFormat = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: micFormat, to: analyzerFormat) else {
            throw KonnyakuError.audioConverterUnavailable
        }
        // tap はオーディオ用 queue から呼ばれるため、@Sendable を明示して
        // MainActor 隔離の暗黙継承を防ぐ (継承すると動的隔離チェックで crash する)
        input.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { @Sendable buffer, _ in
            guard let converted = Self.convert(buffer, with: converter, to: analyzerFormat) else {
                return
            }
            onBuffer(AnalyzerInput(buffer: converted))
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    // internal なのは eval ハーネス (@testable import) がプロダクション経路を再現するため
    nonisolated static func convert(
        _ buffer: AVAudioPCMBuffer,
        with converter: AVAudioConverter,
        to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        if buffer.format == format {
            return buffer
        }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return nil
        }
        var error: NSError?
        let pending = PendingBuffer(buffer)
        converter.convert(to: output, error: &error) { _, inputStatus in
            guard let next = pending.take() else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputStatus.pointee = .haveData
            return next
        }
        return error == nil ? output : nil
    }
}

// @unchecked Sendable の根拠: AVAudioConverter の input block は convert() 内で同一スレッド同期実行されるため並行アクセスしない
private final class PendingBuffer: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}
