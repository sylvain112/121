import AVFoundation
import Foundation

/// Own the audio session rather than inheriting the ASR library's Bluetooth
/// routing. The capture callback only converts and yields; decoding runs apart.
@MainActor
final class MicrophoneCapture {
    enum CaptureError: LocalizedError {
        case inputUnavailable, conversionUnavailable
        var errorDescription: String? {
            switch self {
            case .inputUnavailable: return "没有可用的麦克风输入，请检查麦克风连接。"
            case .conversionUnavailable: return "麦克风音频格式转换失败。"
            }
        }
    }
    private var engine: AVAudioEngine?
    private var observers: [NSObjectProtocol] = []

    var inputDescription: String {
        let input = AVAudioSession.sharedInstance().currentRoute.inputs.first
        guard let input else { return "麦克风未连接" }
        let source = input.selectedDataSource?.dataSourceName
        return [input.portName, source].compactMap { $0 }.joined(separator: " · ")
    }

    func start(preference: MicrophonePreference,
               onChunk: @escaping @Sendable ([Float]) -> Void,
               onError: @escaping @Sendable (String) -> Void) throws {
        stop()
        let session = AVAudioSession.sharedInstance()
        let options: AVAudioSession.CategoryOptions = preference == .automatic ? [.allowBluetooth] : []
        try session.setCategory(.record, mode: .measurement, options: options)
        try? session.setPreferredSampleRate(48_000)
        try? session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true)
        if preference == .phone, let phone = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            if let source = phone.dataSources?.first(where: { $0.orientation == .front }) {
                if source.supportedPolarPatterns?.contains(.omnidirectional) == true {
                    try? source.setPreferredPolarPattern(.omnidirectional)
                }
                try? phone.setPreferredDataSource(source)
            }
            try session.setPreferredInput(phone)
        } else {
            try session.setPreferredInput(nil)
        }

        let captureEngine = AVAudioEngine()
        let input = captureEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.inputUnavailable }
        guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                       channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: mono) else { throw CaptureError.conversionUnavailable }
        converter.downmix = true
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(format.sampleRate / 10), format: format) { buffer, _ in
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16_000 / format.sampleRate) + 32)
            guard let converted = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: capacity) else { return }
            var supplied = false
            var error: NSError?
            let status = converter.convert(to: converted, error: &error) { _, inputStatus in
                guard !supplied else { inputStatus.pointee = .noDataNow; return nil }
                supplied = true
                inputStatus.pointee = .haveData
                return buffer
            }
            if status == .error {
                onError(error?.localizedDescription ?? "麦克风音频转换失败。")
                return
            }
            guard let channel = converted.floatChannelData?[0], converted.frameLength > 0 else { return }
            onChunk(Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength))))
        }
        engine = captureEngine
        do {
            captureEngine.prepare()
            try captureEngine.start()
            observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
                object: session, queue: .main) { notification in
                let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                if type == AVAudioSession.InterruptionType.began.rawValue {
                    onError("麦克风被系统中断，请在通话或系统录音结束后重新开始同传。")
                }
            })
            observers.append(NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                object: captureEngine, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.engine === captureEngine, !captureEngine.isRunning else { return }
                    onError("麦克风连接已改变，请重新开始同传。")
                }
            })
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
        self.engine = nil
    }
}
