import Foundation

/// One socket translates one identified sentence's audio. Continuous streams
/// do not expose sentence IDs, so they cannot safely bind independent ASR rows.
actor RealtimeTranslationSocket {
    enum Target: String { case fr, zh }
    enum SocketError: LocalizedError {
        case invalidResponse, missingSecret, connectionTimeout, outputTimeout, emptyOutput
        case requestFailed(String)
        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "翻译服务器返回格式无效。"
            case .missingSecret: return "后端没有返回临时密钥。"
            case .connectionTimeout: return "实时翻译连接超时。"
            case .outputTimeout: return "等待这句话的最终译文超时，请重试。"
            case .emptyOutput: return "这句话没有收到译文，请重试。"
            case .requestFailed(let message): return message
            }
        }
    }
    private struct SessionResponse: Decodable { let client_secret: String?; let error: String? }
    private let target: Target
    private let backendBaseURL: URL
    private var webSocket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var deltaHandler: (@Sendable (String) -> Void)?
    private var events = TranslationEventBuffer()
    private var ready = false
    private var closed = false
    private var failure: String?
    private var usingDirectAPIKey = false

    init(target: Target, backendBaseURL: URL) {
        self.target = target
        self.backendBaseURL = backendBaseURL
    }

    func translate(
        audio16k: [Float], personalAPIKey: String?,
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        deltaHandler = onDelta
        do {
            try await connect(personalAPIKey: personalAPIKey)
            // Bounded WebSocket messages; preserve the sample order.
            for start in stride(from: 0, to: audio16k.count, by: 3_200) {
                try Task.checkCancellation()
                try await sendAudio16k(Array(audio16k[start..<min(start + 3_200, audio16k.count)]))
            }
            try await sendAudio16k([Float](repeating: 0, count: 9_600))
            try await send(["type": "session.close"])
            // session.close flushes pending translation. Closing the transport
            // immediately would lose the final words of the sentence.
            for _ in 0..<300 {
                try Task.checkCancellation()
                if let failure { throw SocketError.requestFailed(failure) }
                if closed {
                    let text = events.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { throw SocketError.emptyOutput }
                    disconnect()
                    return text
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            throw SocketError.outputTimeout
        } catch {
            disconnect()
            throw error
        }
    }

    private func connect(personalAPIKey: String?) async throws {
        let key = personalAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        usingDirectAPIKey = !key.isEmpty
        let credential: String
        if usingDirectAPIKey { credential = key }
        else { credential = try await createEphemeralSecret() }
        let url = URL(string: "wss://api.openai.com/v1/realtime/translations?model=gpt-realtime-translate")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue("zhfr-live-ios", forHTTPHeaderField: "OpenAI-Safety-Identifier")
        let socket = URLSession.shared.webSocketTask(with: request)
        webSocket = socket
        socket.resume()
        receiveTask = Task { [weak self] in await self?.receiveLoop(socket: socket) }
        for _ in 0..<120 {
            try Task.checkCancellation()
            if let failure { throw SocketError.requestFailed(failure) }
            if ready { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw SocketError.connectionTimeout
    }

    private func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
    }

    private func sendAudio16k(_ samples: [Float]) async throws {
        if let failure { throw SocketError.requestFailed(failure) }
        try await send(["type": "session.input_audio_buffer.append", "audio": PCMConverter.float16kToPCM16Base64_24k(samples)])
    }

    private func send(_ payload: [String: Any]) async throws {
        guard let webSocket else { throw SocketError.invalidResponse }
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let json = String(data: data, encoding: .utf8) else { throw SocketError.invalidResponse }
        try await webSocket.send(.string(json))
    }

    private func createEphemeralSecret() async throws -> String {
        var request = URLRequest(url: backendBaseURL.appending(path: "api/session"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["target": target.rawValue, "transcribe": false])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SocketError.invalidResponse }
        let decoded = try? JSONDecoder().decode(SessionResponse.self, from: data)
        guard (200..<300).contains(http.statusCode) else { throw SocketError.requestFailed(decoded?.error ?? "HTTP \(http.statusCode)") }
        guard let secret = decoded?.client_secret, !secret.isEmpty else { throw SocketError.missingSecret }
        return secret
    }

    private func receiveLoop(socket: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await socket.receive()
                let json: String
                switch message {
                case .string(let value): json = value
                case .data(let data): json = String(data: data, encoding: .utf8) ?? ""
                @unknown default: continue
                }
                switch events.ingest(json) {
                case .created:
                    if usingDirectAPIKey {
                        try await send(["type": "session.update", "session": ["audio": ["input": ["noise_reduction": ["type": "near_field"]], "output": ["language": target.rawValue]]]])
                    } else { ready = true }
                case .updated: ready = true
                case .transcript(let text): deltaHandler?(text)
                case .closed: closed = true; return
                case .error(let message): failure = message; return
                case .ignored: break
                }
            } catch {
                if !Task.isCancelled && !closed { failure = error.localizedDescription }
                return
            }
        }
    }
}
