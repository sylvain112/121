import Foundation

final class MockTranslationProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@main
struct TranslationSmoke {
    static func body(of request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
    static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockTranslationProtocol.self]
        let session = URLSession(configuration: configuration)
        let service = TextTranslationService(backendBaseURL: URL(string: "https://example.invalid")!, session: session)
        func check(_ value: Bool, _ name: String) { if !value { fatalError("FAIL: \(name)") }; print("PASS: \(name)") }
        MockTranslationProtocol.handler = { request in
            let body = try body(of: request)
            check(request.url?.path == "/v1/responses", "personal key uses text Responses API")
            check(body["input"] as? String == "Le semestre a été difficile.", "exact original is translated")
            check(body["audio"] == nil && body["transcription"] == nil, "no audio or paid transcription is submitted")
            check((body["reasoning"] as? [String: String])?["effort"] == "none", "Luna translation skips reasoning")
            return (200, Data(#"{"output":[{"type":"reasoning","content":[]},{"type":"message","content":[{"type":"output_text","text":"这个学期很难。"}]}]}"#.utf8))
        }
        let french = try await service.translate(original: "Le semestre a été difficile.", from: .fr, model: .economy, apiKey: "test-key")
        check(french == "这个学期很难。", "French translation is parsed from output messages")
        MockTranslationProtocol.handler = { request in
            let body = try body(of: request)
            check(request.url?.path == "/api/translate", "missing personal key uses text backend")
            check(body["sourceLang"] as? String == "zh", "backend receives the identified source language")
            return (200, Data(#"{"translation":"Je suis étudiant.","model":"gpt-4o-mini"}"#.utf8))
        }
        let chinese = try await service.translate(original: "我是学生。", from: .zh, model: .mini, apiKey: nil)
        check(chinese == "Je suis étudiant.", "Chinese translation is parsed from backend")
        for (status, code) in [(401, "invalid_api_key"), (429, "credit_balance_exhausted"), (404, "model_not_found")] {
            MockTranslationProtocol.handler = { _ in
                (status, try JSONSerialization.data(withJSONObject: ["error": ["code": code]]))
            }
            do { _ = try await service.translate(original: "Bonjour.", from: .fr, model: .economy, apiKey: "test-key"); fatalError("Expected HTTP error") }
            catch { check(!error.localizedDescription.isEmpty, "HTTP \(status) ends with actionable error") }
        }
        MockTranslationProtocol.handler = { _ in (200, Data(#"{"output":[]}"#.utf8)) }
        do { _ = try await service.translate(original: "Bonjour.", from: .fr, model: .economy, apiKey: "test-key"); fatalError("Expected empty output error") }
        catch { check(error is TextTranslationService.TranslationError, "empty translation exits instead of waiting forever") }
        MockTranslationProtocol.handler = { _ in throw URLError(.timedOut) }
        do { _ = try await service.translate(original: "Bonjour.", from: .fr, model: .economy, apiKey: nil); fatalError("Expected timeout") }
        catch { check(TextTranslationService.userMessage(for: error).contains("超时"), "timeout is displayed briefly and releases the request") }

        if ProcessInfo.processInfo.environment["ZHFR_CHECK_TEXT_TRANSLATION"] == "1" {
            let live = TextTranslationService(backendBaseURL: URL(string: "https://zhfr-live-final.vercel.app")!)
            let result = try await live.translate(original: "Le semestre a été difficile.", from: .fr, model: .economy, apiKey: nil)
            check(result.contains("学期"), "deployed backend French to Chinese")
            let reverse = try await live.translate(original: "我是法国的一名学生。", from: .zh, model: .economy, apiKey: nil)
            check(reverse.lowercased().contains("étudiant"), "deployed backend Chinese to French")
        }
        print("Text-only translation request and failure checks passed.")
    }
}
