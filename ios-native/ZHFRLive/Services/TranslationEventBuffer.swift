import Foundation

/// Server transcript events are append-only. Deduplicate event IDs, never text
/// or elapsed_ms: repeated words and equal timestamps are both legitimate.
struct TranslationEventBuffer {
    enum Event: Equatable {
        case created, updated, transcript(String), closed, error(String), ignored
    }
    private var seenEventIDs: Set<String> = []
    private(set) var transcript = ""

    mutating func ingest(_ json: String) -> Event {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return .ignored }
        if let id = object["event_id"] as? String, !seenEventIDs.insert(id).inserted { return .ignored }
        switch type {
        case "session.created": return .created
        case "session.updated": return .updated
        case "session.closed": return .closed
        case "session.output_transcript.delta":
            guard let delta = object["delta"] as? String else { return .ignored }
            transcript += delta
            return .transcript(transcript)
        case "error":
            let error = object["error"] as? [String: Any]
            return .error(error?["message"] as? String ?? "Realtime Translation error")
        default: return .ignored
        }
    }
}
