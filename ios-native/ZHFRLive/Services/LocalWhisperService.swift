import Foundation
import WhisperKit

@MainActor
final class LocalWhisperService: ObservableObject {
    enum ServiceError: LocalizedError {
        case tokenizerUnavailable, microphoneDenied, audioProcessorUnavailable
        var errorDescription: String? {
            switch self {
            case .tokenizerUnavailable: return "WhisperKit tokenizer 加载失败。"
            case .microphoneDenied: return "没有麦克风权限。"
            case .audioProcessorUnavailable: return "无法取得 WhisperKit 实时麦克风音频。"
            }
        }
    }

    @Published private(set) var modelReady = false
    @Published private(set) var modelStatus = "尚未加载本地模型"
    @Published private(set) var liveText = ""
    let modelName = "large-v3-v20240930_626MB"
    var onTextChanged: ((String) -> Void)?
    var onAudioChunk: (([Float]) -> Void)?
    var onSentence: ((RecognizedSentence, [Float]) -> Void)?
    var onError: ((String) -> Void)?

    private var whisperKit: WhisperKit?
    private var preparationTask: Task<WhisperKit, Error>?
    private var transcriptionTask: Task<Void, Never>?
    private var audioBuffer = SentenceAudioBuffer()
    private var assembler = SentenceAssembler()
    private var isRecording = false
    private var transcriptGeneration = UUID()
    private var recordingGeneration = UUID()
    private var lastVoiceSample = 0
    private var lastDecodedSample = 0

    func prepare() async throws {
        guard !modelReady else { return }
        modelStatus = "正在下载 / 加载本地 Whisper 模型…"
        let task: Task<WhisperKit, Error>
        if let existing = preparationTask { task = existing }
        else {
            let config = WhisperKitConfig(model: modelName, verbose: false, prewarm: true, load: true,
                download: true, useBackgroundDownloadSession: true)
            task = Task { try await WhisperKit(config) }
            preparationTask = task
        }
        defer { preparationTask = nil }
        let pipeline = try await task.value
        guard pipeline.tokenizer != nil else { throw ServiceError.tokenizerUnavailable }
        whisperKit = pipeline
        modelReady = true
        modelStatus = "本地模型已就绪 · \(modelName)"
    }

    func start() async throws {
        guard !isRecording else { return }
        guard await AudioProcessor.requestRecordPermission() else { throw ServiceError.microphoneDenied }
        guard let processor = whisperKit?.audioProcessor as? AudioProcessor else { throw ServiceError.audioProcessorUnavailable }
        audioBuffer = SentenceAudioBuffer()
        assembler.reset()
        lastVoiceSample = 0
        lastDecodedSample = 0
        liveText = ""
        transcriptGeneration = UUID()
        recordingGeneration = UUID()
        let generation = recordingGeneration
        isRecording = true
        do {
            // Keep the callback installed from the first microphone frame.
            try processor.startRecordingLive { [weak self, weak processor] chunk in
                // Purge on the capture callback's own thread, not concurrently
                // with AudioProcessor appending to its buffer.
                processor?.purgeAudioSamples(keepingLast: SentenceAudioBuffer.sampleRate * 2)
                Task { @MainActor [weak self] in
                    guard let self, self.isRecording, self.recordingGeneration == generation else { return }
                    self.receiveAudio(chunk)
                }
            }
        } catch {
            isRecording = false
            throw error
        }
        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            while self.isRecording && !Task.isCancelled {
                do {
                    if self.audioBuffer.endSample - self.lastDecodedSample >= SentenceAudioBuffer.sampleRate {
                        try await self.decode(force: false)
                    }
                    try await Task.sleep(nanoseconds: 100_000_000)
                } catch {
                    if !Task.isCancelled {
                        self.modelStatus = "本地转写错误：\(error.localizedDescription)"
                        self.onError?(self.modelStatus)
                    }
                    break
                }
            }
        }
    }

    func stop() async {
        isRecording = false
        whisperKit?.audioProcessor.stopRecording()
        // Model state is shared, so wait before doing the final local decode.
        await transcriptionTask?.value
        transcriptionTask = nil
        do { try await decode(force: true) }
        catch { onError?("结束转写失败：\(error.localizedDescription)") }
    }

    func clearTranscript() {
        // Invalidate an in-flight result without invalidating microphone input.
        transcriptGeneration = UUID()
        assembler.reset(at: audioBuffer.endTime)
        audioBuffer.clearKeepingClock()
        lastVoiceSample = audioBuffer.endSample
        lastDecodedSample = audioBuffer.endSample
        liveText = ""
        onTextChanged?("")
    }

    private func receiveAudio(_ chunk: [Float]) {
        guard !chunk.isEmpty else { return }
        audioBuffer.append(chunk)
        let rms = sqrt(chunk.reduce(Float(0)) { $0 + $1 * $1 } / Float(chunk.count))
        if rms >= 0.008 { lastVoiceSample = audioBuffer.endSample }
        onAudioChunk?(chunk)
    }

    private func decode(force: Bool) async throws {
        guard let pipeline = whisperKit, !audioBuffer.samples.isEmpty else { return }
        let generation = transcriptGeneration
        let snapshot = audioBuffer
        let sampleEnd = snapshot.endSample
        let offset = Double(snapshot.baseSample) / Double(SentenceAudioBuffer.sampleRate)
        let silenceDuration = Double(max(0, sampleEnd - lastVoiceSample)) / Double(SentenceAudioBuffer.sampleRate)
        lastDecodedSample = sampleEnd
        let results = try await pipeline.transcribe(
            audioArray: snapshot.samples,
            decodeOptions: DecodingOptions(
                task: .transcribe, language: nil, detectLanguage: true,
                withoutTimestamps: false, wordTimestamps: true, suppressTokens: []
            )
        )
        guard generation == transcriptGeneration else { return }
        let words = results.flatMap(\.segments).filter { $0.noSpeechProb < 0.85 }.flatMap { segment -> [TimedWord] in
            if let timings = segment.words, !timings.isEmpty {
                return timings.map { word in
                    TimedWord(text: SentenceAssembler.clean(word.word), start: offset + Double(word.start), end: offset + Double(word.end))
                }
            }
            return [TimedWord(text: SentenceAssembler.clean(segment.text), start: offset + Double(segment.start), end: offset + Double(segment.end))]
        }.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let sentences = assembler.update(words: words, silenceDuration: silenceDuration, force: force)
        for sentence in sentences {
            let audio = snapshot.audio(from: sentence.start, to: sentence.end)
            guard !audio.isEmpty else { continue }
            onSentence?(sentence, audio)
        }
        liveText = assembler.liveText
        onTextChanged?(liveText)
        audioBuffer.discard(before: assembler.consumedThrough)
        if words.isEmpty && silenceDuration >= 3 {
            audioBuffer.discard(before: snapshot.endTime - 0.3)
            assembler.reset(at: Double(audioBuffer.baseSample) / Double(SentenceAudioBuffer.sampleRate))
        }
    }
}
