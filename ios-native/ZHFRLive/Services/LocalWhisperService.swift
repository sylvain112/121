import Foundation
import WhisperKit

@MainActor
final class LocalWhisperService: ObservableObject {
    enum ServiceError: LocalizedError {
        case tokenizerUnavailable, microphoneDenied
        var errorDescription: String? {
            switch self {
            case .tokenizerUnavailable: return "WhisperKit tokenizer 加载失败。"
            case .microphoneDenied: return "没有麦克风权限。"
            }
        }
    }

    @Published private(set) var modelReady = false
    @Published private(set) var isPreparingModel = false
    @Published private(set) var modelStatus = "尚未加载本地模型"
    @Published private(set) var liveText = ""
    @Published private(set) var inputDescription = "优先手机麦克风"
    @Published private(set) var inputGain: Float = 1
    @Published private(set) var decodeDuration: Double = 0
    @Published private(set) var isDecoding = false
    var onTextChanged: ((String) -> Void)?
    var onAudioChunk: (([Float]) -> Void)?
    var onSentence: ((RecognizedSentence) -> Void)?
    var onError: ((String) -> Void)?

    private let microphone = MicrophoneCapture()
    private var whisperKit: WhisperKit?
    private var loadedModel: String?
    private var preparationTask: Task<WhisperKit, Error>?
    private var preparingModel: String?
    private var transcriptionTask: Task<Void, Never>?
    private var audioTask: Task<Void, Never>?
    private var audioContinuation: AsyncStream<[Float]>.Continuation?
    private var audioBuffer = SentenceAudioBuffer()
    private var assembler = SentenceAssembler()
    private var signalProcessor = MicrophoneSignalProcessor()
    private var language = RecognitionLanguage.automatic
    private var boost = true
    private var isRecording = false
    private var transcriptGeneration = UUID()
    private var recordingGeneration = UUID()
    private var activeDecodeID: UUID?
    private var lastVoiceSample = 0
    private var lastDecodedSample = 0
    private var lastMeterSample = 0
    private var lastPreviewAt = Date.distantPast

    func prepare(profile: RecognitionProfile) async throws {
        let modelName = profile.modelName
        guard !modelReady || loadedModel != modelName else { return }
        if let existing = preparationTask {
            if preparingModel == modelName { _ = try await existing.value }
            else {
                _ = try? await existing.value
                try await prepare(profile: profile)
            }
            return
        }
        modelReady = false
        isPreparingModel = true
        preparingModel = modelName
        whisperKit = nil
        loadedModel = nil
        let task = Task<WhisperKit, Error> { [self] in
            defer {
                isPreparingModel = false
                preparationTask = nil
                preparingModel = nil
            }
            do {
                let cache = LocalModelCache()
                try cache.prepareDirectories()
                let complete = cache.completedFolder(for: profile)
                let existing = try complete ?? cache.existingCandidate(for: profile)
                var folder: URL
                if let existing {
                    folder = existing
                    modelStatus = "正在加载已保存模型 · \(profile.description)…"
                } else {
                    try cache.prepareRepair(for: profile)
                    folder = try await downloadModel(profile, cache: cache)
                }
                let pipeline: WhisperKit
                do {
                    pipeline = try await loadModel(profile, folder: folder, cache: cache, completed: complete != nil)
                } catch {
                    guard complete == nil, existing != nil, !Task.isCancelled else { throw error }
                    // A v2.4 or interrupted cache is not considered complete
                    // until the actual model load succeeds. Repair it once.
                    folder = try await downloadModel(profile, cache: cache)
                    pipeline = try await loadModel(profile, folder: folder, cache: cache, completed: false)
                }
                try BilingualWhisperConfiguration.restrict(pipeline)
                if complete == nil { try cache.markCompleted(folder, profile: profile) }
                whisperKit = pipeline
                loadedModel = modelName
                modelReady = true
                modelStatus = "本地模型已保存 · \(profile.description)"
                return pipeline
            } catch {
                modelStatus = "本地模型准备失败，可重试"
                let detail = error.localizedDescription
                if detail.contains("NSURLErrorDomain") || error is URLError {
                    throw PreparationError.downloadInterrupted
                }
                if let error = error as? LocalModelCache.CacheError { throw error }
                throw PreparationError.loadingFailed
            }
        }
        preparationTask = task
        _ = try await task.value
    }

    private func downloadModel(_ profile: RecognitionProfile, cache: LocalModelCache) async throws -> URL {
        modelStatus = "下载或修复 · \(profile.description)…请保持 App 在前台"
        let folder = try await WhisperKit.download(variant: profile.modelName, downloadBase: cache.root,
            useBackgroundSession: false) { [weak self] progress in
            let percent = Int(progress.fractionCompleted * 100)
            Task { @MainActor [weak self] in
                guard let self, self.preparingModel == profile.modelName,
                      self.modelStatus.hasPrefix("下载或修复") else { return }
                self.modelStatus = "下载或修复 · \(profile.description) · \(percent)%"
            }
        }
        modelStatus = "文件已下载，正在加载 · \(profile.description)…"
        return folder
    }

    private func loadModel(_ profile: RecognitionProfile, folder: URL, cache: LocalModelCache,
                           completed: Bool) async throws -> WhisperKit {
        let config = WhisperKitConfig(model: profile.modelName, downloadBase: cache.root,
            modelFolder: folder.path, tokenizerFolder: completed ? folder : cache.root,
            verbose: false, prewarm: true, load: true, download: false,
            useBackgroundDownloadSession: false)
        return try await WhisperKit(config)
    }

    enum PreparationError: LocalizedError {
        case downloadInterrupted, loadingFailed
        var errorDescription: String? {
            switch self {
            case .downloadInterrupted: return "模型下载未完成。请检查网络并保持 App 在前台，然后点击重试；已下载文件会保留。"
            case .loadingFailed: return "本地模型加载失败。请重试或在设置中切换模型。"
            }
        }
    }

    func start(language: RecognitionLanguage, microphonePreference: MicrophonePreference, boost: Bool) async throws {
        guard !isRecording else { return }
        guard await AudioProcessor.requestRecordPermission() else { throw ServiceError.microphoneDenied }
        self.language = language
        self.boost = boost
        audioBuffer = SentenceAudioBuffer()
        assembler.reset()
        signalProcessor = MicrophoneSignalProcessor()
        lastVoiceSample = 0
        lastDecodedSample = 0
        lastMeterSample = 0
        decodeDuration = 0
        isDecoding = false
        inputGain = 1
        liveText = ""
        transcriptGeneration = UUID()
        recordingGeneration = UUID()
        let generation = recordingGeneration
        let stream = AsyncStream<[Float]>.makeStream()
        audioContinuation = stream.continuation
        audioTask = Task { [weak self] in
            for await chunk in stream.stream {
                guard let self, self.recordingGeneration == generation else { return }
                self.receiveAudio(chunk)
            }
        }
        isRecording = true
        do {
            try microphone.start(preference: microphonePreference,
                onChunk: { stream.continuation.yield($0) },
                onError: { [weak self] message in
                    Task { @MainActor [weak self] in
                        guard let self, self.recordingGeneration == generation, self.isRecording else { return }
                        self.onError?(message)
                    }
                })
            inputDescription = microphone.inputDescription
        } catch {
            isRecording = false
            microphone.stop()
            stream.continuation.finish()
            await audioTask?.value
            audioTask = nil
            audioContinuation = nil
            throw error
        }
        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            while self.isRecording && !Task.isCancelled {
                do {
                    let pendingVoice = self.lastVoiceSample > self.lastDecodedSample || !self.assembler.liveText.isEmpty
                    if pendingVoice && self.audioBuffer.endSample - self.lastDecodedSample >= 8_800 {
                        try await self.decode(force: false)
                    } else if self.audioBuffer.endSample - self.lastVoiceSample > 48_000 && self.assembler.liveText.isEmpty {
                        // Idle capture must not build an unbounded decoding window.
                        self.audioBuffer.discard(before: self.audioBuffer.endTime - 0.3)
                        self.assembler.reset(at: Double(self.audioBuffer.baseSample) / 16_000)
                    }
                    try await Task.sleep(nanoseconds: 80_000_000)
                } catch {
                    if !Task.isCancelled {
                        self.onError?("本地转写错误：\(error.localizedDescription)")
                    }
                    break
                }
            }
        }
    }

    func stop() async {
        isRecording = false
        microphone.stop()
        audioContinuation?.finish()
        await audioTask?.value
        audioTask = nil
        audioContinuation = nil
        await transcriptionTask?.value
        transcriptionTask = nil
        do { try await decode(force: true) }
        catch { onError?("结束转写失败：\(error.localizedDescription)") }
    }

    func clearTranscript() {
        transcriptGeneration = UUID()
        activeDecodeID = nil
        assembler.reset(at: audioBuffer.endTime)
        audioBuffer.clearKeepingClock()
        lastVoiceSample = audioBuffer.endSample
        lastDecodedSample = audioBuffer.endSample
        liveText = ""
        onTextChanged?("")
    }

    private func receiveAudio(_ chunk: [Float]) {
        guard !chunk.isEmpty else { return }
        let frame = signalProcessor.process(chunk, boost: boost)
        audioBuffer.append(frame.samples)
        if frame.hasVoice { lastVoiceSample = audioBuffer.endSample }
        if audioBuffer.endSample - lastMeterSample >= 1_600 {
            lastMeterSample = audioBuffer.endSample
            inputGain = frame.gain
            let description = microphone.inputDescription
            if inputDescription != description { inputDescription = description }
            onAudioChunk?(chunk)
        }
    }

    private func decode(force: Bool) async throws {
        guard let pipeline = whisperKit, !audioBuffer.samples.isEmpty else { return }
        if force && assembler.liveText.isEmpty && lastVoiceSample <= Int(assembler.consumedThrough * 16_000) { return }
        let generation = transcriptGeneration
        let decodeID = UUID()
        activeDecodeID = decodeID
        lastPreviewAt = .distantPast
        isDecoding = true
        defer {
            if activeDecodeID == decodeID { activeDecodeID = nil }
            isDecoding = false
        }
        let snapshot = audioBuffer
        let offset = Double(snapshot.baseSample) / 16_000
        let silenceDuration = Double(max(0, snapshot.endSample - lastVoiceSample)) / 16_000
        lastDecodedSample = snapshot.endSample
        let started = Date()
        let results = try await pipeline.transcribe(
            audioArray: snapshot.samples,
            decodeOptions: BilingualWhisperConfiguration.options(language: language,
                clipStart: assembler.consumedThrough - offset, final: force),
            callback: { [weak self] progress in
                let text = LanguageDetector.approvedText(progress.text)
                Task { @MainActor [weak self] in
                    guard let self, self.transcriptGeneration == generation, self.activeDecodeID == decodeID else { return }
                    let now = Date()
                    guard self.liveText != text, now.timeIntervalSince(self.lastPreviewAt) >= 0.12 else { return }
                    self.lastPreviewAt = now
                    self.liveText = text
                    self.onTextChanged?(text)
                }
                return nil
            }
        )
        guard generation == transcriptGeneration else { return }
        // Do not overwrite the last real recognition time with a skipped,
        // empty decoder loop (previously displayed as a misleading 0.0 s).
        if results.contains(where: { $0.timings.totalEncodingRuns > 0 }) {
            decodeDuration = Date().timeIntervalSince(started)
        }
        let words = results.filter { $0.language == "zh" || $0.language == "fr" }
            .flatMap(\.segments).filter { $0.noSpeechProb < 0.85 }.flatMap { segment -> [TimedWord] in
            if let timings = segment.words, !timings.isEmpty {
                return timings.map { word in
                    TimedWord(text: SentenceAssembler.clean(word.word), start: offset + Double(word.start), end: offset + Double(word.end))
                }
            }
            return [TimedWord(text: SentenceAssembler.clean(segment.text), start: offset + Double(segment.start), end: offset + Double(segment.end))]
        }.compactMap { $0.bounded(from: offset, to: snapshot.endTime) }
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        // Word timestamps supply a second pause signal when background noise
        // keeps the microphone energy detector active after speech has ended.
        let wordSilence = words.last.map { max(0, snapshot.endTime - $0.end) } ?? 0
        let sentences = assembler.update(words: words, silenceDuration: max(silenceDuration, wordSilence),
            force: force, audioEnd: snapshot.endTime)
        for sentence in sentences { onSentence?(sentence) }
        // Invalidate delayed progress callbacks before publishing the final tail.
        activeDecodeID = nil
        liveText = assembler.liveText
        onTextChanged?(liveText)
        audioBuffer.discard(before: assembler.consumedThrough - 0.18)
        if words.isEmpty && silenceDuration >= 3 {
            audioBuffer.discard(before: snapshot.endTime - 0.3)
            assembler.reset(at: Double(audioBuffer.baseSample) / 16_000)
        }
    }
}
