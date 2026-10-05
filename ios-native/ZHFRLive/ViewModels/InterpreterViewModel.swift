import AVFoundation
import Foundation
import SwiftUI

@MainActor
final class InterpreterViewModel: ObservableObject {
    @Published var isRunning = false
    @Published var isChangingState = false
    @Published var status = "准备就绪"
    @Published var liveSource = ""
    @Published var detectedLanguage: TranscriptLine.SourceLanguage?
    @Published var lines: [TranscriptLine] = []
    @Published var lastError = ""
    @Published var recognizedText = ""
    @Published var micLevel: Float = 0
    @Published var audioChunkCount = 0
    @Published var summaryText = ""
    @Published var isSummarizing = false
    @Published var exportItem: ExportItem?
    let whisper = LocalWhisperService()
    let settings = AppSettings()

    private struct TranslationJob { let lineID: UUID; let audio: [Float] }
    private let backendURL = URL(string: "https://zhfr-live-final.vercel.app")!
    private lazy var summaryService = AISummaryService(backendBaseURL: backendURL)
    private var jobs: [TranslationJob] = []
    private var retryAudio: [UUID: [Float]] = [:]
    private var queuedIDs: Set<UUID> = []
    private var bindings = TranslationBindings()
    private var translationTask: Task<Void, Never>?
    private var recordGeneration = UUID()

    init() {
        whisper.onTextChanged = { [weak self] text in
            guard let self else { return }
            self.liveSource = text
            self.detectedLanguage = LanguageDetector.detect(text) ?? self.lines.last?.sourceLanguage
            self.rebuildRecognizedText()
        }
        whisper.onSentence = { [weak self] sentence, audio in self?.enqueue(sentence, audio: audio) }
        whisper.onAudioChunk = { [weak self] chunk in self?.handleMicChunk(chunk) }
        whisper.onError = { [weak self] message in
            guard let self else { return }
            self.handleError(message)
            if self.isRunning && !self.isChangingState { Task { await self.stop() } }
        }
    }

    func prepareModel() async {
        do {
            try await whisper.prepare()
            if !isRunning && !isChangingState { status = whisper.modelStatus }
        } catch { handleError(error.localizedDescription) }
    }

    func toggle() async {
        guard !isChangingState else { return }
        if isRunning { await stop() } else { await start() }
    }

    func start() async {
        guard !isRunning, !isChangingState else { return }
        isChangingState = true
        defer { isChangingState = false }
        lastError = ""
        liveSource = ""
        audioChunkCount = 0
        micLevel = 0
        status = "正在准备本地 Whisper…"
        do {
            try await whisper.prepare()
            status = "正在启动麦克风…"
            try await whisper.start()
            isRunning = true
            refreshStatus()
        } catch {
            handleError(error.localizedDescription)
            await whisper.stop()
        }
    }

    func stop() async {
        guard !isChangingState else { return }
        isChangingState = true
        status = "正在完成最后一句转写…"
        await whisper.stop()
        isRunning = false
        micLevel = 0
        isChangingState = false
        refreshStatus()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        // Translation jobs keep draining; stopping the mic does not discard them.
    }

    func clear() {
        recordGeneration = UUID()
        translationTask?.cancel()
        translationTask = nil
        jobs.removeAll()
        retryAudio.removeAll()
        queuedIDs.removeAll()
        bindings.clear()
        lines.removeAll()
        liveSource = ""
        recognizedText = ""
        summaryText = ""
        isSummarizing = false
        detectedLanguage = nil
        whisper.clearTranscript()
        refreshStatus()
    }

    func retryTranslation(_ lineID: UUID) {
        guard !queuedIDs.contains(lineID), let audio = retryAudio[lineID],
              let index = lines.firstIndex(where: { $0.id == lineID }) else { return }
        lines[index].translation = ""
        lines[index].translationError = nil
        jobs.append(TranslationJob(lineID: lineID, audio: audio))
        queuedIDs.insert(lineID)
        startTranslationWorker()
    }

    func summarize() async {
        guard !recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastError = "当前还没有可总结的转写内容。"
            return
        }
        guard !isSummarizing else { return }
        let generation = recordGeneration
        var snapshot = lines
        if !liveSource.isEmpty, let language = LanguageDetector.detect(liveSource) {
            snapshot.append(TranscriptLine(sourceLanguage: language, original: liveSource, translation: ""))
        }
        isSummarizing = true
        lastError = ""
        defer { if generation == recordGeneration { isSummarizing = false } }
        do {
            let text = try await summaryService.summarize(lines: snapshot, rawTranscript: recognizedText,
                apiKey: settings.currentAPIKey(), model: settings.summaryModel)
            if generation == recordGeneration { summaryText = text }
        } catch {
            if generation == recordGeneration { lastError = error.localizedDescription }
        }
    }

    func prepareTranscriptExport() {
        let text = recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { lastError = "当前没有可以导出的语音转文字内容。"; return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ZHFR-Transcript-\(formatter.string(from: Date())).txt")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            exportItem = ExportItem(url: url)
        } catch { lastError = "导出失败：\(error.localizedDescription)" }
    }

    private func enqueue(_ sentence: RecognizedSentence, audio: [Float]) {
        guard !lines.contains(where: { $0.id == sentence.id }) else { return }
        lines.append(TranscriptLine(id: sentence.id, sourceLanguage: sentence.sourceLanguage,
            original: sentence.original, translation: ""))
        detectedLanguage = sentence.sourceLanguage
        retryAudio[sentence.id] = audio
        jobs.append(TranslationJob(lineID: sentence.id, audio: audio))
        queuedIDs.insert(sentence.id)
        rebuildRecognizedText()
        startTranslationWorker()
    }

    private func startTranslationWorker() {
        guard translationTask == nil else { return }
        let generation = recordGeneration
        translationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == self.recordGeneration {
                    self.translationTask = nil
                    self.refreshStatus()
                }
            }
            while !self.jobs.isEmpty && !Task.isCancelled && generation == self.recordGeneration {
                let job = self.jobs.removeFirst()
                guard let line = self.lines.first(where: { $0.id == job.lineID }) else { continue }
                self.refreshStatus()
                let target: RealtimeTranslationSocket.Target = line.sourceLanguage == .zh ? .fr : .zh
                let socket = RealtimeTranslationSocket(target: target, backendBaseURL: self.backendURL)
                let ticket = self.bindings.begin(lineID: job.lineID)
                do {
                    let text = try await socket.translate(audio16k: job.audio, personalAPIKey: self.settings.currentAPIKey()) { [weak self] text in
                        Task { @MainActor [weak self] in self?.updateTranslation(text, ticket: ticket, final: false) }
                    }
                    guard !Task.isCancelled, generation == self.recordGeneration else { return }
                    self.updateTranslation(text, ticket: ticket, final: true)
                    self.retryAudio.removeValue(forKey: job.lineID)
                } catch {
                    guard !Task.isCancelled, generation == self.recordGeneration else { return }
                    if let index = self.lines.firstIndex(where: { $0.id == job.lineID }) {
                        self.lines[index].translationError = error.localizedDescription
                    }
                    self.bindings.finish(ticket)
                }
                self.queuedIDs.remove(job.lineID)
            }
        }
        refreshStatus()
    }

    private func updateTranslation(_ text: String, ticket: TranslationTicket, final: Bool) {
        guard bindings.accepts(ticket),
              let index = lines.firstIndex(where: { $0.id == ticket.lineID }) else { return }
        // Delayed UI tasks cannot replace a newer cumulative streaming snapshot.
        if final || text.count >= lines[index].translation.count { lines[index].translation = text }
        if final { bindings.finish(ticket) }
    }

    private func rebuildRecognizedText() {
        recognizedText = (lines.map(\.original) + (liveSource.isEmpty ? [] : [liveSource])).joined(separator: "\n")
    }

    private func refreshStatus() {
        if !lastError.isEmpty { status = "出现错误" }
        else if isRunning { status = queuedIDs.isEmpty ? "同传中" : "同传中 · \(queuedIDs.count) 句正在翻译" }
        else { status = queuedIDs.isEmpty ? "已停止" : "录音已停止 · 正在完成 \(queuedIDs.count) 句译文" }
    }

    private func handleMicChunk(_ chunk: [Float]) {
        audioChunkCount += 1
        guard !chunk.isEmpty else { micLevel = 0; return }
        let rms = sqrt(chunk.reduce(Float(0)) { $0 + $1 * $1 } / Float(chunk.count))
        micLevel = min(1, rms * 10)
    }

    private func handleError(_ message: String) { lastError = message; status = "出现错误" }
}
