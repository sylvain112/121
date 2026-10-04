import Foundation

struct AISummaryService {
    enum SummaryError: LocalizedError {
        case invalidResponse
        case requestFailed(String)
        case emptySummary

        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "AI 总结返回格式无效。"
            case .requestFailed(let message): return "AI 总结失败：\(message)"
            case .emptySummary: return "AI 没有返回总结内容。"
            }
        }
    }

    let backendBaseURL: URL

    func summarize(
        lines: [TranscriptLine],
        rawTranscript: String,
        apiKey: String?,
        model: String
    ) async throws -> String {
        if let apiKey, !apiKey.isEmpty {
            return try await summarizeDirect(lines: lines, rawTranscript: rawTranscript, apiKey: apiKey, model: model)
        }
        return try await summarizeViaBackend(lines: lines, rawTranscript: rawTranscript)
    }

    private func transcriptText(lines: [TranscriptLine], rawTranscript: String) -> String {
        if !lines.isEmpty {
            return lines.enumerated().map { index, line in
                let direction = line.sourceLanguage == .zh ? "中文→法语" : "法语→中文"
                return "\(index + 1). [\(direction)]\n原文：\(line.original)\n译文：\(line.translation)"
            }.joined(separator: "\n\n")
        }
        return rawTranscript.isEmpty ? "（暂无可用转写）" : rawTranscript
    }

    private func summarizeDirect(
        lines: [TranscriptLine],
        rawTranscript: String,
        apiKey: String,
        model: String
    ) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let input = transcriptText(lines: lines, rawTranscript: rawTranscript)
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model.isEmpty ? "gpt-6-astra" : model,
            "reasoning": ["effort": "medium"],
            "instructions": "你是中法现场同传记录整理助手。用简体中文总结，忠于原文，不要虚构。优先整理：对话概要、关键信息、明确结论、待办事项、时间、金额、地址或联系方式。听写可能有错误，不确定处标注‘待确认’。",
            "input": input
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SummaryError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let error = object?["error"] as? [String: Any]
            throw SummaryError.requestFailed(error?["message"] as? String ?? "HTTP \(http.statusCode)")
        }
        let text = extractResponseText(data)
        guard !text.isEmpty else { throw SummaryError.emptySummary }
        return text
    }

    private func summarizeViaBackend(lines: [TranscriptLine], rawTranscript: String) async throws -> String {
        let url = backendBaseURL.appending(path: "api/assistant")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var transcript = lines.map { line -> [String: String] in
            [
                "sourceLang": line.sourceLanguage.rawValue,
                "time": ISO8601DateFormatter().string(from: line.createdAt),
                "original": line.original,
                "translation": line.translation
            ]
        }
        if transcript.isEmpty && !rawTranscript.isEmpty {
            transcript = [[
                "sourceLang": "unknown",
                "time": ISO8601DateFormatter().string(from: Date()),
                "original": rawTranscript,
                "translation": ""
            ]]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "mode": "summary",
            "topic": "中法现场同传",
            "transcript": transcript
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SummaryError.invalidResponse }
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard (200..<300).contains(http.statusCode) else {
            throw SummaryError.requestFailed(object?["error"] as? String ?? "HTTP \(http.statusCode)")
        }
        let text = (object?["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SummaryError.emptySummary }
        return text
    }

    private func extractResponseText(_ data: Data) -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = root["output"] as? [[String: Any]] else { return "" }
        var parts: [String] = []
        for item in output {
            guard let content = item["content"] as? [[String: Any]] else { continue }
            for part in content {
                if let text = part["text"] as? String { parts.append(text) }
            }
        }
        return parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
