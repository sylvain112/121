import Foundation

struct TranscriptLine: Identifiable, Codable, Equatable {
    enum SourceLanguage: String, Codable {
        case zh
        case fr
    }

    let id: UUID
    let createdAt: Date
    let sourceLanguage: SourceLanguage
    let original: String
    let translation: String

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        sourceLanguage: SourceLanguage,
        original: String,
        translation: String
    ) {
        self.id = id
        self.createdAt = createdAt
        self.sourceLanguage = sourceLanguage
        self.original = original
        self.translation = translation
    }
}
