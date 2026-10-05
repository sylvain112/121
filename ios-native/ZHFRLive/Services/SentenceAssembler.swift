import Foundation

struct TimedWord: Equatable, Sendable {
    let text: String
    let start: Double
    let end: Double
}

struct RecognizedSentence: Identifiable, Sendable {
    let id: UUID
    let original: String
    let sourceLanguage: TranscriptLine.SourceLanguage
    let start: Double
    let end: Double
}

/// Accept completed decoding snapshots, replacing the revisable tail each time.
/// Audio positions, rather than text equality, identify already accepted speech.
struct SentenceAssembler {
    private struct Candidate {
        let words: [TimedWord]
        let hasBoundary: Bool
        var text: String { words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines) }
        var start: Double { words.first?.start ?? 0 }
        var end: Double { words.last?.end ?? 0 }
    }
    private struct Observation {
        let text: String
        let start: Double
        let count: Int
    }

    private(set) var consumedThrough: Double = 0
    private(set) var liveText = ""
    private var observations: [Observation] = []

    mutating func reset(at time: Double = 0) {
        consumedThrough = time
        liveText = ""
        observations.removeAll()
    }

    mutating func update(words: [TimedWord], silenceDuration: Double, force: Bool = false,
                         audioEnd: Double? = nil) -> [RecognizedSentence] {
        let remaining = words.filter { $0.start >= consumedThrough - 0.025 && $0.end > consumedThrough + 0.005 }
        var candidates: [Candidate] = []
        var current: [TimedWord] = []
        for word in remaining {
            if let last = current.last,
               word.start - last.end >= 1.1,
               Self.canEndAtPause(current.map(\.text).joined(), silenceDuration: word.start - last.end) {
                candidates.append(Candidate(words: current, hasBoundary: true))
                current = []
            }
            current.append(word)
            let text = current.map(\.text).joined()
            if Self.endsSentence(text) || (word.end - (current.first?.start ?? word.start) >= 15 && text.count >= 60) {
                candidates.append(Candidate(words: current, hasBoundary: true))
                current = []
            }
        }
        if !current.isEmpty { candidates.append(Candidate(words: current, hasBoundary: false)) }
        let nextObservations = candidates.map { candidate -> Observation in
            let previous = observations.first { $0.text == candidate.text && abs($0.start - candidate.start) < 0.25 }
            return Observation(text: candidate.text, start: candidate.start, count: (previous?.count ?? 0) + 1)
        }
        observations = nextObservations
        var sentences: [RecognizedSentence] = []
        for (index, candidate) in candidates.enumerated() {
            let stable = nextObservations[index].count >= 2
            let pause = silenceDuration >= 0.75 && Self.canEndAtPause(candidate.text, silenceDuration: silenceDuration)
            // A punctuated sentence away from the live edge can be emitted on
            // its first complete decode. Keep edge drafts revisable as before.
            let settledBoundary = candidate.hasBoundary && (audioEnd.map { $0 - candidate.end >= 0.35 } ?? false)
            let settledPause = candidate.hasBoundary && silenceDuration >= 0.75
            guard force || settledBoundary || settledPause || (stable && (candidate.hasBoundary || pause)) else { break }
            guard let language = LanguageDetector.detect(candidate.text), !candidate.text.isEmpty else { break }
            sentences.append(RecognizedSentence(id: UUID(), original: candidate.text, sourceLanguage: language, start: candidate.start, end: candidate.end))
            consumedThrough = candidate.end
        }
        liveText = remaining.filter { $0.start >= consumedThrough - 0.025 && $0.end > consumedThrough + 0.005 }
            .map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return sentences
    }

    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "<\\|[^>]+\\|>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "Waiting for speech...", with: "")
    }

    private static func endsSentence(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'»”’）)]}"))
        guard let last = value.last, ".?!。？！…".contains(last) else { return false }
        let lastWord = value.split(whereSeparator: \.isWhitespace).last?.lowercased() ?? ""
        return !["m.", "mme.", "mlle.", "dr.", "pr.", "etc."].contains(lastWord)
    }

    private static func canEndAtPause(_ text: String, silenceDuration: Double) -> Bool {
        if silenceDuration >= 2.2 { return true }
        let value = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if ["oui", "non", "merci", "salut", "bonjour", "好", "好的", "是", "对", "谢谢"].contains(value) { return true }
        return text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count >= 4
    }
}

/// The decoder and translator slice the same audio on a shared sample clock.
struct SentenceAudioBuffer {
    static let sampleRate = 16_000
    private(set) var samples: [Float] = []
    private(set) var baseSample = 0
    var endSample: Int { baseSample + samples.count }
    var endTime: Double { Double(endSample) / Double(Self.sampleRate) }

    mutating func append(_ chunk: [Float]) { samples.append(contentsOf: chunk) }

    func audio(from start: Double, to end: Double) -> [Float] {
        let lower = max(baseSample, Int((start * Double(Self.sampleRate)).rounded(.down)))
        let upper = min(endSample, Int((end * Double(Self.sampleRate)).rounded(.up)))
        guard lower < upper else { return [] }
        return Array(samples[(lower - baseSample)..<(upper - baseSample)])
    }

    mutating func discard(before time: Double) {
        let count = min(samples.count, max(0, Int(time * Double(Self.sampleRate)) - baseSample))
        samples.removeFirst(count)
        baseSample += count
    }

    mutating func clearKeepingClock() {
        baseSample = endSample
        samples.removeAll(keepingCapacity: true)
    }
}
