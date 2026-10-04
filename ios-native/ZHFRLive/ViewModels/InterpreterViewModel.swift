import AVFoundation
import Foundation
import SwiftUI

@MainActor
final class InterpreterViewModel: ObservableObject {
    @Published var isRunning = false
    @Published var status = "准备就绪"
    @Published var liveSource = ""
    @Published var liveTranslation = ""
    @Published var detectedLanguage: TranscriptLine.SourceLanguage?
    @Published var frenchDraft = ""
    @Published var chineseDraft = ""
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

    private let backendURL = URL(string: "https://zhfr-live-final.vercel.app")!
    private lazy var frSocket = RealtimeTranslationSocket(target: .fr, backendBaseURL: backendURL)
    private lazy var zhSocket = RealtimeTranslationSocket(target: .zh, backendBaseURL: backendURL)
    private lazy var summaryService = AISummaryService(backendBaseURL: backendURL)

    private var previousSource = ""
    private var pendingOriginal = ""
    private var pendingTranslation = ""

    init() {
        whisper.onTextChanged = { [weak self] text in
            self?.handleLocalText(text)
        }
        whisper.onAudioChunk = { [weak self] chunk in
            guard let self else { return }
            self.handleMicChunk(chunk)
            Task {
                await self.frSocket.sendAudio16k(chunk)
                await self.zhSocket.sendAudio16k(chunk)
            }
        }
    }

    func prepareModel() async {
        do {
            try await whisper.prepare()
            status = whisper.modelStatus
        } catch {
            lastError = error.localizedDescription
            status = "模型加载失败"
        }
    }

    func toggle() async {
        if isRunning {
            await stop()
        } else {
            await start()
        }
    }

    func start() async {
        guard !isRunning else { return }
        lastError = ""
        liveSource = ""
        liveTranslation = ""
        frenchDraft = ""
        chineseDraft = ""
        previousSource = ""
        pendingOriginal = ""
        pendingTranslation = ""
        recognizedText = ""
        audioChunkCount = 0
        micLevel = 0
        status = "正在准备本地 Whisper…"

        do {
            try await whisper.prepare()

            await frSocket.setHandlers(
                onDelta: { [weak self] delta in
                    Task { @MainActor in self?.handleFrenchDelta(delta) }
                },
                onError: { [weak self] message in
                    Task { @MainActor in self?.handleError(message) }
                }
            )
            await zhSocket.setHandlers(
                onDelta: { [weak self] delta in
                    Task { @MainActor in self?.handleChineseDelta(delta) }
                },
                onError: { [weak self] message in
                    Task { @MainActor in self?.handleError(message) }
                }
            )

            status = settings.currentAPIKey() == nil ? "正在连接服务器临时翻译密钥…" : "正在连接个人 API…"
            let key = settings.currentAPIKey()
            async let frConnect: Void = frSocket.connect(personalAPIKey: key)
            async let zhConnect: Void = zhSocket.connect(personalAPIKey: key)
            _ = try await (frConnect, zhConnect)

            status = "正在启动本地麦克风…"
            try await whisper.start()
            isRunning = true
            status = "同传中"
        } catch {
            handleError(error.localizedDescription)
            await stop()
        }
    }

    func stop() async {
        finalizeCurrentLineIfPossible()
        await whisper.stop()
        await frSocket.disconnect()
        await zhSocket.disconnect()
        isRunning = false
        micLevel = 0
        if lastError.isEmpty { status = "已停止" }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func clear() {
        lines.removeAll()
        liveSource = ""
        liveTranslation = ""
        frenchDraft = ""
        chineseDraft = ""
        previousSource = ""
        pendingOriginal = ""
        pendingTranslation = ""
        recognizedText = ""
        summaryText = ""
        detectedLanguage = nil
    }

    func summarize() async {
        guard !recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !lines.isEmpty else {
            lastError = "当前还没有可总结的转写内容。"
            return
        }
        isSummarizing = true
        lastError = ""
        defer { isSummarizing = false }
        do {
            summaryText = try await summaryService.summarize(
                lines: lines,
                rawTranscript: recognizedText,
                apiKey: settings.currentAPIKey(),
                model: settings.summaryModel
            )
        } catch {
            lastError = error.localizedDescription
        }
    }

    func prepareTranscriptExport() {
        let text: String
        if !recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = recognizedText
        } else {
            text = lines.map(\.original).joined(separator: "\n")
        }
        guard !text.isEmpty else {
            lastError = "当前没有可以导出的语音转文字内容。"
            return
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZHFR-Transcript-\(formatter.string(from: Date())).txt")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            exportItem = ExportItem(url: url)
        } catch {
            lastError = "导出失败：\(error.localizedDescription)"
        }
    }

    private func handleMicChunk(_ chunk: [Float]) {
        audioChunkCount += 1
        guard !chunk.isEmpty else { micLevel = 0; return }
        var sum: Float = 0
        for value in chunk { sum += value * value }
        let rms = sqrt(sum / Float(chunk.count))
        micLevel = min(1, rms * 10)
    }

    private func handleLocalText(_ text: String) {
        let cleaned = text
            .replacingOccurrences(of: "Waiting for speech...", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }

        liveSource = cleaned
        recognizedText = cleaned

        if cleaned.count < previousSource.count {
            finalizeCurrentLineIfPossible()
            frenchDraft = ""
            chineseDraft = ""
        }

        previousSource = cleaned
        pendingOriginal = cleaned
        detectedLanguage = LanguageDetector.detect(cleaned)
        refreshSelectedTranslation()
    }

    private func handleFrenchDelta(_ delta: String) {
        frenchDraft += delta
        refreshSelectedTranslation()
    }

    private func handleChineseDelta(_ delta: String) {
        chineseDraft += delta
        refreshSelectedTranslation()
    }

    private func refreshSelectedTranslation() {
        switch detectedLanguage {
        case .zh:
            liveTranslation = frenchDraft
        case .fr:
            liveTranslation = chineseDraft
        case .none:
            if !frenchDraft.isEmpty && chineseDraft.isEmpty {
                liveTranslation = frenchDraft
            } else if !chineseDraft.isEmpty && frenchDraft.isEmpty {
                liveTranslation = chineseDraft
            }
        }
        pendingTranslation = liveTranslation
    }

    private func finalizeCurrentLineIfPossible() {
        let original = pendingOriginal.trimmingCharacters(in: .whitespacesAndNewlines)
        let translation = pendingTranslation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !original.isEmpty,
            !translation.isEmpty,
            let language = detectedLanguage
        else { return }

        let line = TranscriptLine(
            sourceLanguage: language,
            original: original,
            translation: translation
        )
        if lines.last != line {
            lines.append(line)
        }

        pendingOriginal = ""
        pendingTranslation = ""
    }

    private func handleError(_ message: String) {
        lastError = message
        status = "出现错误"
    }
}
