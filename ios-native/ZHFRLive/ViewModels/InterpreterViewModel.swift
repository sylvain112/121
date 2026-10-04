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

    let whisper = LocalWhisperService()

    private let backendURL = URL(string: "https://zhfr-live-final.vercel.app")!
    private lazy var frSocket = RealtimeTranslationSocket(target: .fr, backendBaseURL: backendURL)
    private lazy var zhSocket = RealtimeTranslationSocket(target: .zh, backendBaseURL: backendURL)

    private var previousSource = ""
    private var pendingOriginal = ""
    private var pendingTranslation = ""

    init() {
        whisper.onTextChanged = { [weak self] text in
            self?.handleLocalText(text)
        }
        whisper.onAudioChunk = { [weak self] chunk in
            guard let self else { return }
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
        status = "正在准备本地 Whisper…"

        do {
            try configureAudioSession()
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

            status = "正在连接实时翻译…"
            async let frConnect: Void = frSocket.connect()
            async let zhConnect: Void = zhSocket.connect()
            _ = try await (frConnect, zhConnect)

            try await whisper.start()
            isRunning = true
            status = "同传中"
        } catch {
            handleError(error.localizedDescription)
            await stop()
        }
    }

    func stop() async {
        await whisper.stop()
        await frSocket.disconnect()
        await zhSocket.disconnect()
        isRunning = false
        status = "已停止"
        finalizeCurrentLineIfPossible()
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
        detectedLanguage = nil
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setPreferredSampleRate(16_000)
        try session.setActive(true)
    }

    private func handleLocalText(_ text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        liveSource = cleaned

        if cleaned.count < previousSource.count || (previousSource.count > 8 && cleaned.isEmpty) {
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
