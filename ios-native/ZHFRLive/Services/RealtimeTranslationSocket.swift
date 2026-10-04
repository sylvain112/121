import Foundation

actor RealtimeTranslationSocket {
    enum Target: String {
        case fr
        case zh
    }

    enum SocketError: LocalizedError {
        case invalidBackendURL
        case sessionCreationFailed(String)
        case missingSecret
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .invalidBackendURL:
                return "无效的后端地址。"
            case .sessionCreationFailed(let message):
                return "创建翻译会话失败：\(message)"
            case .missingSecret:
                return "后端没有返回临时密钥。"
            case .invalidResponse:
                return "后端返回格式无效。"
            }
        }
    }

    private struct SessionResponse: Decodable {
        let client_secret: String?
        let error: String?
    }

    private let target: Target
    private let backendBaseURL: URL
    private var webSocket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var deltaHandler: (@Sendable (String) -> Void)?
    private var errorHandler: (@Sendable (String) -> Void)?

    init(target: Target, backendBaseURL: URL) {
        self.target = target
        self.backendBaseURL = backendBaseURL
    }

    func setHandlers(
        onDelta: @escaping @Sendable (String) -> Void,
        onError: @escaping @Sendable (String) -> Void
    ) {
        deltaHandler = onDelta
        errorHandler = onError
    }

    func connect() async throws {
        let secret = try await createEphemeralSecret()

        guard let wsURL = URL(string: "wss://api.openai.com/v1/realtime/translations?model=gpt-realtime-translate") else {
            throw SocketError.invalidBackendURL
        }

        var request = URLRequest(url: wsURL)
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        request.setValue("zhfr-live-ios", forHTTPHeaderField: "OpenAI-Safety-Identifier")

        let socket = URLSession.shared.webSocketTask(with: request)
        webSocket = socket
        socket.resume()
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
    }

    func sendAudio16k(_ samples: [Float]) async {
        guard !samples.isEmpty, let webSocket else { return }
        let audio = PCMConverter.float16kToPCM16Base64_24k(samples)
        guard !audio.isEmpty else { return }

        let payload: [String: Any] = [
            "type": "session.input_audio_buffer.append",
            "audio": audio
        ]

        guard
            let data = try? JSONSerialization.data(withJSONObject: payload),
            let json = String(data: data, encoding: .utf8)
        else { return }

        do {
            try await webSocket.send(.string(json))
        } catch {
            errorHandler?("\(target.rawValue.uppercased()) 音频发送失败：\(error.localizedDescription)")
        }
    }

    private func createEphemeralSecret() async throws -> String {
        let url = backendBaseURL.appending(path: "api/session")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "target": target.rawValue,
            "transcribe": false
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SocketError.invalidResponse
        }

        let decoded = try? JSONDecoder().decode(SessionResponse.self, from: data)
        guard (200..<300).contains(http.statusCode) else {
            throw SocketError.sessionCreationFailed(decoded?.error ?? "HTTP \(http.statusCode)")
        }

        guard let secret = decoded?.client_secret, !secret.isEmpty else {
            throw SocketError.missingSecret
        }
        return secret
    }

    private func receiveLoop() async {
        guard let webSocket else { return }

        while !Task.isCancelled {
            do {
                let message = try await webSocket.receive()
                let text: String
                switch message {
                case .string(let value):
                    text = value
                case .data(let data):
                    text = String(data: data, encoding: .utf8) ?? ""
                @unknown default:
                    continue
                }
                handleEvent(text)
            } catch {
                if !Task.isCancelled {
                    errorHandler?("\(target.rawValue.uppercased()) 通道断开：\(error.localizedDescription)")
                }
                break
            }
        }
    }

    private func handleEvent(_ json: String) {
        guard
            let data = json.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = object["type"] as? String
        else { return }

        if type == "session.output_transcript.delta", let delta = object["delta"] as? String {
            deltaHandler?(delta)
            return
        }

        if type == "error" {
            let errorObject = object["error"] as? [String: Any]
            let message = errorObject?["message"] as? String ?? "Realtime Translation error"
            errorHandler?("\(target.rawValue.uppercased())：\(message)")
        }
    }
}
