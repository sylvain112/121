import Foundation
import WhisperKit

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw NSError(domain: "ZHFRSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

func processedAudio(path: String) throws -> [Float] {
    let input = try AudioProcessor.loadAudioAsFloatArray(fromPath: path)
    var processor = MicrophoneSignalProcessor()
    var output: [Float] = []
    for start in stride(from: 0, to: input.count, by: 1_600) {
        output += processor.process(Array(input[start..<min(start + 1_600, input.count)]), boost: true).samples
    }
    output += [Float](repeating: 0, count: 12_800)
    return output
}

func checkTranslation(audio: [Float], source: TranscriptLine.SourceLanguage) async throws {
    let target: RealtimeTranslationSocket.Target = source == .fr ? .zh : .fr
    var result = ""
    let start = Date()
    for attempt in 0..<2 {
        let socket = RealtimeTranslationSocket(target: target,
            backendBaseURL: URL(string: "https://zhfr-live-final.vercel.app")!,
            noiseReduction: attempt == 0 ? "far_field" : nil)
        do {
            result = try await socket.translate(audio16k: audio, personalAPIKey: nil, onDelta: { _ in })
            break
        } catch RealtimeTranslationSocket.SocketError.emptyOutput where attempt == 0 {
            continue
        }
    }
    try require(!result.isEmpty, "Actual live translation returned no text")
    try require(LanguageDetector.detect(result) == (source == .fr ? .zh : .fr), "Actual live translation returned the wrong target language")
    print("LIVE \(source.rawValue) -> \(target.rawValue): \(result) [\(String(format: "%.2f", Date().timeIntervalSince(start))) s, Mac runner]")
}

do {
    let directory = CommandLine.arguments[1]
    let pipeline = try await WhisperKit(WhisperKitConfig(model: "openai_whisper-base", verbose: false,
        prewarm: true, load: true, download: true))
    try BilingualWhisperConfiguration.restrict(pipeline)
    let tokenizer = pipeline.tokenizer as! BilingualWhisperTokenizer
    let allowed = Set([tokenizer.convertTokenToId("<|fr|>")!, tokenizer.convertTokenToId("<|zh|>")!])
    try require(tokenizer.allLanguageTokens == allowed, "Language detector must allow exactly French and Chinese")
    try require(!tokenizer.blockedLanguageTokens.isEmpty, "Other Whisper languages must be suppressed")

    for source in [TranscriptLine.SourceLanguage.fr, .zh] {
        let audio = try processedAudio(path: "\(directory)/\(source.rawValue).aiff")
        let start = Date()
        let results = try await pipeline.transcribe(audioArray: audio,
            decodeOptions: BilingualWhisperConfiguration.options(language: .automatic, final: true))
        let text = SentenceAssembler.clean(results.map(\.text).joined(separator: " "))
        print("ASR \(source.rawValue): \(text) [\(String(format: "%.2f", Date().timeIntervalSince(start))) s, Mac runner]")
        try require(!results.isEmpty && results.allSatisfy { $0.language == source.rawValue }, "Bilingual ASR detected an unexpected language")
        try require(LanguageDetector.detect(text) == source, "Bilingual ASR produced unsuitable text")
        if source == .fr { try require(text.lowercased().contains("bonjour"), "French speech lost the opening sentence") }
        else { try require(text.contains("法国"), "Chinese speech lost the main subject") }

        let words = results.flatMap(\.segments).flatMap { segment in
            (segment.words ?? []).map { TimedWord(text: $0.word, start: Double($0.start), end: Double($0.end)) }
        }
        var assembler = SentenceAssembler()
        let duration = Double(audio.count) / 16_000
        let sentences = assembler.update(words: words, silenceDuration: 0.8, force: true, audioEnd: duration)
        try require(!sentences.isEmpty, "Actual ASR timestamps produced no final sentence")
        try require(assembler.consumedThrough <= duration, "Actual ASR timestamps skipped beyond the recording")
        try require(sentences.allSatisfy { $0.sourceLanguage == source }, "Actual ASR sentence language differs from the source")

        if ProcessInfo.processInfo.environment["ZHFR_CHECK_LIVE_TRANSLATION"] == "1" {
            try await checkTranslation(audio: audio, source: source)
        }
    }
    print("Actual base-model bilingual ASR, bounded timestamps and translation smoke checks passed.")
} catch {
    // Never print request bodies or ephemeral credentials.
    print("FAIL bilingual speech smoke check: \(error.localizedDescription)")
    exit(1)
}
