import Foundation

enum TranscriptWindow {
    static let limit = 4
    static func recent(_ lines: [TranscriptLine], hasDraft: Bool) -> [TranscriptLine] {
        Array(lines.suffix(limit - (hasDraft ? 1 : 0)))
    }
}
