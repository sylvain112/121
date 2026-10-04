import Foundation

enum LanguageDetector {
    static func detect(_ text: String) -> TranscriptLine.SourceLanguage? {
        let scalars = text.unicodeScalars
        let hanCount = scalars.filter { scalar in
            (0x3400...0x4DBF).contains(Int(scalar.value)) ||
            (0x4E00...0x9FFF).contains(Int(scalar.value))
        }.count

        let latinCount = scalars.filter { scalar in
            CharacterSet.letters.contains(scalar) &&
            !((0x3400...0x4DBF).contains(Int(scalar.value)) ||
              (0x4E00...0x9FFF).contains(Int(scalar.value)))
        }.count

        if hanCount >= 1 { return .zh }
        if latinCount >= 3 { return .fr }
        return nil
    }
}
