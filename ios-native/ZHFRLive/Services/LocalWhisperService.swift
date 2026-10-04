import Foundation
import WhisperKit

@MainActor
final class LocalWhisperService: ObservableObject {
    enum ServiceError: LocalizedError {
        case tokenizerUnavailable
        case microphoneDenied

        var errorDescription: String? {
            switch self {
            case .tokenizerUnavailable:
                return "WhisperKit tokenizer 加载失败。"
            case .microphoneDenied:
                return "没有麦克风权限。"
            }
        }
    }

    @Published private(set) var modelReady = false
    @Published private(set) var modelStatus = "尚未加载本地模型"
    @Published private(set) var liveText = ""

    let modelName = "large-v3-v20240930_626MB"

    var onTextChanged: ((String) -> Void)?
    var onAudioChunk: (([Float]) -> Void)?

    private var whisperKit: WhisperKit?
    private var streamTranscriber: AudioStreamTranscriber?
    private var transcriptionTask: Task<Void, Never>?

    func prepare() async throws {
        guard !modelReady else { return }
        modelStatus = "正在下载 / 加载本地 Whisper 模型…"

        let config = WhisperKitConfig(
            model: modelName,
            verbose: false,
            prewarm: true,
            load: true,
            download: true,
            useBackgroundDownloadSession: true
        )

        let pipeline = try await WhisperKit(config)
        guard let tokenizer = pipeline.tokenizer else {
            throw ServiceError.tokenizerUnavailable
        }

        let options = DecodingOptions(
            task: .transcribe,
            language: nil,
            detectLanguage: true,
            withoutTimestamps: true,
            wordTimestamps: false,
            suppressTokens: []
        )

        let transcriber = AudioStreamTranscriber(
            audioEncoder: pipeline.audioEncoder,
            featureExtractor: pipeline.featureExtractor,
            segmentSeeker: pipeline.segmentSeeker,
            textDecoder: pipeline.textDecoder,
            tokenizer: tokenizer,
            audioProcessor: pipeline.audioProcessor,
            decodingOptions: options,
            requiredSegmentsForConfirmation: 1,
            silenceThreshold: 0.3,
            compressionCheckWindow: 60,
            useVAD: true
        ) { [weak self] _, newState in
            let confirmed = newState.confirmedSegments.map(\.text).joined(separator: " ")
            let pending = newState.unconfirmedText.joined(separator: " ")
            let current = newState.currentText
            let combined = [confirmed, pending, current]
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.liveText = combined
                self.onTextChanged?(combined)
            }
        }

        whisperKit = pipeline
        streamTranscriber = transcriber
        modelReady = true
        modelStatus = "本地模型已就绪 · \(modelName)"
    }

    func start() async throws {
        guard await AudioProcessor.requestRecordPermission() else {
            throw ServiceError.microphoneDenied
        }
        guard let transcriber = streamTranscriber else { return }

        transcriptionTask?.cancel()
        transcriptionTask = Task {
            do {
                try await transcriber.startStreamTranscription()
            } catch {
                if !Task.isCancelled {
                    await MainActor.run {
                        self.modelStatus = "本地转写错误：\(error.localizedDescription)"
                    }
                }
            }
        }

        try? await Task.sleep(nanoseconds: 250_000_000)
        if let processor = whisperKit?.audioProcessor as? AudioProcessor {
            processor.audioBufferCallback = { [weak self] chunk in
                guard let self else { return }
                Task { @MainActor in
                    self.onAudioChunk?(chunk)
                }
            }
        }
    }

    func stop() async {
        if let transcriber = streamTranscriber {
            await transcriber.stopStreamTranscription()
        }
        transcriptionTask?.cancel()
        transcriptionTask = nil
        liveText = ""
    }
}
