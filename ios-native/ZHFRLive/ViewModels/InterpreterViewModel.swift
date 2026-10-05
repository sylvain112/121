import AVFoundation
import Combine
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
    @Published private(set) var retryingIDs: Set<UUID> = []
    let whisper = LocalWhisperService()
    let settings = AppSettings()

    private struct TranslationJob { let lineID: UUID }
    private let backendURL = URL(string: "https://zhfr-live-final.vercel.app")!
    private lazy var summaryService = AISummaryService(backendBaseURL: backendURL)
    private lazy var translationService = TextTranslationService(backendBaseURL: backendURL)
    private var jobs: [TranslationJob] = []
    private var queuedIDs: Set<UUID> = []
    private var bindings = TranslationBindings()
    private var translationTasks: [UUID: Task<Void, Never>] = [:]
    private var observations: Set<AnyCancellable> = []
    private var recordGeneration = UUID()

    init() {
        whisper.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        settings.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        whisper.onTextChanged = { [weak self] text in
            guard let self else { return }
            self.liveSource = text
            self.detectedLanguage = LanguageDetector.detect(text) ?? self.lines.last?.sourceLanguage
            self.rebuildRecognizedText()
        }
        whisper.onSentence = { [weak self] sentence in self?.enqueue(sentence) }
        whisper.onAudioChunk = { [weak self] chunk in self?.handleMicChunk(chunk) }
        whisper.onError = { [weak self] message in
            guard let self else { return }
            self.handleError(message)
            if self.isRunning && !self.isChangingState { Task { await self.stop() } }
        }
    }

    func prepareModel() async {
        guard !isRunning, !isChangingState else { return }
        lastError = ""
        do {
            try await whisper.prepare(profile: settings.recognitionProfile)
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
            try await whisper.prepare(profile: settings.recognitionProfile)
            status = "正在启动麦克风…"
            try await whisper.start(language: settings.recognitionLanguage,
                microphonePreference: settings.microphone, boost: settings.pickupBoost)
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
        for task in translationTasks.values { task.cancel() }
        translationTasks.removeAll()
        jobs.removeAll()
        queuedIDs.removeAll()
        retryingIDs.removeAll()
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
        guard !queuedIDs.contains(lineID),
              let index = lines.firstIndex(where: { $0.id == lineID }) else { return }
        lines[index].translation = ""
        lines[index].translationError = nil
        retryingIDs.insert(lineID)
        jobs.append(TranslationJob(lineID: lineID))
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

    private func enqueue(_ sentence: RecognizedSentence) {
        guard !lines.contains(where: { $0.id == sentence.id }) else { return }
        lines.append(TranscriptLine(id: sentence.id, sourceLanguage: sentence.sourceLanguage,
            original: sentence.original, translation: ""))
        detectedLanguage = sentence.sourceLanguage
        jobs.append(TranslationJob(lineID: sentence.id))
        queuedIDs.insert(sentence.id)
        rebuildRecognizedText()
        startTranslationWorker()
    }

    private func startTranslationWorker() {
        // Concurrent sentences can finish out of order; their IDs keep
        // displayed originals and translations in the original speaking order.
        while translationTasks.count < 3 && !jobs.isEmpty {
            let job = jobs.removeFirst()
            guard let line = lines.first(where: { $0.id == job.lineID }) else {
                queuedIDs.remove(job.lineID)
                continue
            }
            let generation = recordGeneration
            let key = settings.currentAPIKey()
            translationTasks[job.lineID] = Task { [weak self] in
                guard let self else { return }
                await self.translate(job, line: line, apiKey: key, generation: generation)
                guard generation == self.recordGeneration else { return }
                self.translationTasks.removeValue(forKey: job.lineID)
                self.queuedIDs.remove(job.lineID)
                self.retryingIDs.remove(job.lineID)
                self.startTranslationWorker()
            }
        }
        refreshStatus()
    }

    private func translate(_ job: TranslationJob, line: TranscriptLine, apiKey: String?, generation: UUID) async {
        guard !Task.isCancelled, generation == recordGeneration else { return }
        if let text = PhraseTranslator.translate(line.original, from: line.sourceLanguage) {
            let ticket = bindings.begin(lineID: job.lineID)
            updateTranslation(text, ticket: ticket, final: true)
            return
        }
        let ticket = bindings.begin(lineID: job.lineID)
        do {
            let text = try await translationService.translate(original: line.original, from: line.sourceLanguage,
                model: settings.translationModel, apiKey: apiKey)
            guard !Task.isCancelled, generation == recordGeneration else { return }
            updateTranslation(text, ticket: ticket, final: true)
        } catch {
            guard !Task.isCancelled, generation == recordGeneration else { return }
            bindings.finish(ticket)
            if let index = lines.firstIndex(where: { $0.id == job.lineID }) {
                lines[index].translationError = TextTranslationService.userMessage(for: error)
            }
        }
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
