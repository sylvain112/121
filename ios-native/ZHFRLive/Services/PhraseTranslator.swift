import Foundation

/// Exact standalone greetings and acknowledgements need no network round-trip.
/// Never match a substring or shorten a longer sentence.
enum PhraseTranslator {
    private static let french: [String: String] = [
        "oui": "是的", "non": "不", "merci": "谢谢", "merci beaucoup": "非常感谢",
        "bonjour": "你好", "bonsoir": "晚上好", "au revoir": "再见", "d'accord": "好的"
    ]
    private static let chinese: [String: String] = [
        "是的": "Oui", "不": "Non", "谢谢": "Merci", "非常感谢": "Merci beaucoup",
        "你好": "Bonjour", "晚上好": "Bonsoir", "再见": "Au revoir", "好的": "D'accord"
    ]

    static func translate(_ original: String, from source: TranscriptLine.SourceLanguage) -> String? {
        let value = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let phrase = value.trimmingCharacters(in: CharacterSet(charactersIn: ".!?。！？"))
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "’", with: "'")
        guard let translation = (source == .fr ? french : chinese)[phrase] else { return nil }
        let suffix: String
        switch value.last {
        case "?", "？": suffix = source == .fr ? "？" : " ?"
        case "!", "！": suffix = source == .fr ? "！" : " !"
        default: suffix = source == .fr ? "。" : "."
        }
        return translation + suffix
    }
}
