import Foundation
import NaturalLanguage

enum LanguageDetector {
    static func detect(_ text: String) -> TranscriptLine.SourceLanguage? {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return nil }
        // Other scripts must never be displayed as French or Chinese.
        guard letters.allSatisfy({ isHan($0.value) || isLatin($0.value) }) else { return nil }
        if letters.contains(where: { isHan($0.value) }) { return .zh }
        // The speech model is constrained to two languages. This additional
        // text check rejects confidently foreign Latin-language hypotheses.
        if letters.count >= 10, text.split(whereSeparator: \.isWhitespace).count >= 2 {
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(text)
            let probabilities = recognizer.languageHypotheses(withMaximum: 5)
            if let dominant = recognizer.dominantLanguage, dominant != .french,
               (probabilities[dominant] ?? 0) >= 0.9,
               (probabilities[.french] ?? 0) < 0.15 { return nil }
        }
        return .fr
    }

    static func approvedText(_ text: String) -> String {
        let value = SentenceAssembler.clean(text).trimmingCharacters(in: .whitespacesAndNewlines)
        return detect(value) == nil ? "" : value
    }

    private static func isHan(_ value: UInt32) -> Bool {
        value == 0x3007 || (0x3400...0x4DBF).contains(value) || (0x4E00...0x9FFF).contains(value) ||
            (0xF900...0xFAFF).contains(value) || (0x20000...0x323AF).contains(value)
    }

    private static func isLatin(_ value: UInt32) -> Bool {
        (0x0041...0x007A).contains(value) || (0x00C0...0x024F).contains(value) || (0x1E00...0x1EFF).contains(value)
    }
}
