import Foundation

var passed = 0
func expect(_ condition: @autoclosure () -> Bool, _ description: String) {
    guard condition() else { fatalError("FAIL: \(description)") }
    passed += 1
    print("PASS: \(description)")
}
func word(_ text: String, _ start: Double, _ end: Double) -> TimedWord {
    TimedWord(text: text, start: start, end: end)
}

var assembler = SentenceAssembler()
let first = [word("Le semestre a été difficile.", 0, 2)]
expect(assembler.update(words: first, silenceDuration: 0).isEmpty, "one snapshot is still revisable")
let accepted = assembler.update(words: first, silenceDuration: 0)
expect(accepted.map(\.original) == ["Le semestre a été difficile."], "accept one stable complete sentence")
expect(assembler.update(words: first, silenceDuration: 0).isEmpty, "replayed cumulative source is not recorded twice")
let grown = first + [word(" Tu es allé en cours?", 2.3, 4)]
expect(assembler.update(words: grown, silenceDuration: 0).isEmpty, "new sentence needs its own confirmation")
expect(assembler.update(words: grown, silenceDuration: 0).map(\.original) == ["Tu es allé en cours?"], "only newly spoken sentence is accepted")

assembler.reset()
let fragment = [word("你没", 0, 0.5)]
_ = assembler.update(words: fragment, silenceDuration: 1.2)
expect(assembler.update(words: fragment, silenceDuration: 1.2).isEmpty, "brief pause does not save a two-character fragment")
let correction = [word("你没有学习。", 0, 1.6)]
expect(assembler.update(words: correction, silenceDuration: 0).isEmpty, "revised hypothesis replaces the fragment")
expect(assembler.update(words: correction, silenceDuration: 0).map(\.original) == ["你没有学习。"], "corrected sentence is recorded once")

assembler.reset()
let repeated = [word("Oui.", 0, 0.4), word(" Oui.", 0.6, 1)]
_ = assembler.update(words: repeated, silenceDuration: 0)
let repetitions = assembler.update(words: repeated, silenceDuration: 0)
expect(repetitions.map(\.original) == ["Oui.", "Oui."], "real repeated speech at different times is retained")
expect(repetitions[0].id != repetitions[1].id, "identical real sentences get independent IDs")

assembler.reset()
let shortReply = [word("谢谢", 0, 0.5)]
_ = assembler.update(words: shortReply, silenceDuration: 1.2)
expect(assembler.update(words: shortReply, silenceDuration: 1.2).map(\.original) == ["谢谢"], "a real short acknowledgement is not dropped")
assembler.reset()
let unfinished = [word("Je vais à Poitiers", 0, 2)]
expect(assembler.update(words: unfinished, silenceDuration: 0).isEmpty, "unpunctuated active phrase stays a draft")
expect(assembler.update(words: unfinished, silenceDuration: 0, force: true).map(\.original) == ["Je vais à Poitiers"], "stop flushes the final unpunctuated phrase")

assembler.reset()
let gap = [word("Je viens demain", 0, 1), word(" 我明天来。", 2.5, 4)]
_ = assembler.update(words: gap, silenceDuration: 0)
expect(assembler.update(words: gap, silenceDuration: 0).map(\.sourceLanguage) == [.fr, .zh], "audio pause separates a bilingual speaker change")
assembler.reset(at: 5)
expect(assembler.update(words: first, silenceDuration: 3, force: true).isEmpty, "clear excludes all speech before its audio cursor")
expect(assembler.update(words: [word("Bonjour.", 5.1, 6)], silenceDuration: 0, force: true).count == 1, "microphone can continue after clear")

assembler.reset()
let price = [word("Je", 0, 0.1), word(" paie", 0.1, 0.5), word(" 12.5", 0.5, 1), word(" euros.", 1, 1.5)]
_ = assembler.update(words: price, silenceDuration: 0)
expect(assembler.update(words: price, silenceDuration: 0).map(\.original) == ["Je paie 12.5 euros."], "decimal number is not a sentence boundary")
assembler.reset()
let name = [word("M.", 0, 0.2), word(" Dupont", 0.2, 0.5), word(" arrive.", 0.5, 1)]
_ = assembler.update(words: name, silenceDuration: 0)
expect(assembler.update(words: name, silenceDuration: 0).map(\.original) == ["M. Dupont arrive."], "French title is not split into its own sentence")
expect(SentenceAssembler.clean("<|fr|>Bonjour.<|endoftext|>") == "Bonjour.", "Whisper control tokens remain hidden")

var audio = SentenceAudioBuffer()
audio.append((0..<8).map(Float.init))
let rate = Double(SentenceAudioBuffer.sampleRate)
expect(audio.audio(from: 2 / rate, to: 5 / rate) == [2, 3, 4], "translation uses the sentence's own audio samples")
audio.discard(before: 3 / rate)
expect(audio.baseSample == 3 && audio.audio(from: 4 / rate, to: 7 / rate) == [4, 5, 6], "pruning preserves the global sample clock")
audio.clearKeepingClock()
audio.append([8, 9])
expect(audio.baseSample == 8 && audio.endSample == 10, "clear does not reset the clock during a recording")

var events = TranslationEventBuffer()
let e1 = #"{"type":"session.output_transcript.delta","event_id":"1","delta":"你","elapsed_ms":1000}"#
let e2 = #"{"type":"session.output_transcript.delta","event_id":"2","delta":"好","elapsed_ms":1000}"#
expect(events.ingest(e1) == .transcript("你"), "stream first Chinese fragment")
expect(events.ingest(e1) == .ignored, "duplicate event ID is ignored")
expect(events.ingest(e2) == .transcript("你好"), "equal timestamps are not deduplicated and Chinese gets no added spaces")
_ = events.ingest(#"{"type":"session.output_transcript.delta","event_id":"3","delta":"，你好。"}"#)
expect(events.transcript == "你好，你好。", "intentional repeated words in translation are kept")
expect(events.ingest(#"{"type":"session.closed","event_id":"4"}"#) == .closed, "close acknowledgement ends the completed sentence")

var bindings = TranslationBindings()
let idA = UUID(), idB = UUID()
let ticketA = bindings.begin(lineID: idA)
let ticketB = bindings.begin(lineID: idB)
expect(ticketA.lineID == idA && ticketB.lineID == idB && bindings.accepts(ticketA), "translation tickets bind to explicit sentence IDs")
bindings.finish(ticketB)
expect(bindings.accepts(ticketA) && !bindings.accepts(ticketB), "finishing a later response does not consume another sentence")
let retryA = bindings.begin(lineID: idA)
expect(!bindings.accepts(ticketA) && bindings.accepts(retryA), "retry rejects the previous attempt's late response")
bindings.clear()
expect(!bindings.accepts(retryA), "clear rejects in-flight translation callbacks")
let newTicket = bindings.begin(lineID: UUID())
bindings.finish(newTicket)
expect(!bindings.accepts(newTicket), "late partial text cannot overwrite a final translation")
assembler.reset()
expect(assembler.update(words: first, silenceDuration: 0, audioEnd: 2.4).map(\.original) == ["Le semestre a été difficile."], "completed sentence with following audio avoids a second full decode")
expect(assembler.update(words: first, silenceDuration: 0, audioEnd: 3).isEmpty, "fast confirmation still rejects replayed audio")
assembler.reset()
expect(assembler.update(words: first, silenceDuration: 0, audioEnd: 2.1).isEmpty, "a sentence on the live edge stays revisable")
expect(assembler.update(words: first, silenceDuration: 0.8, audioEnd: 2.1).count == 1, "punctuation plus short silence completes the sentence")
assembler.reset()
expect(assembler.update(words: fragment, silenceDuration: 0.8, audioEnd: 1.4).isEmpty, "fast mode does not split an unpunctuated two-character fragment")

let history = (0..<7).map { index in
    TranscriptLine(sourceLanguage: .fr, original: "Phrase \(index).", translation: "译文 \(index)。")
}
expect(TranscriptWindow.recent(history, hasDraft: false).map(\.id) == Array(history.suffix(4)).map(\.id), "default screen keeps the newest four original-translation pairs in speaking order")
expect(TranscriptWindow.recent(history, hasDraft: true).map(\.id) == Array(history.suffix(3)).map(\.id), "a live original occupies the fourth slot instead of hiding the newest sentences")
expect(history.count == 7 && history.first?.original == "Phrase 0.", "visible window does not discard historical originals")
expect(TranscriptWindow.recent([], hasDraft: true).isEmpty, "first draft does not require existing records")

func tone(amplitude: Float) -> [Float] {
    (0..<1_600).map { amplitude * Float(sin(2 * Double.pi * 160 * Double($0) / 16_000)) }
}
var signal = MicrophoneSignalProcessor()
let quiet = signal.process(tone(amplitude: 0.0001), boost: true)
expect(!quiet.hasVoice && quiet.gain <= 1.01, "quiet background is not promoted to speech by pickup boost")
let weak = signal.process(tone(amplitude: 0.006), boost: true)
expect(weak.hasVoice && weak.gain > 1, "weak real speech is detected before amplification and receives bounded gain")
var sustained = weak
for _ in 0..<80 { sustained = signal.process(tone(amplitude: 0.006), boost: true) }
expect(sustained.hasVoice && sustained.gain <= 4, "sustained quiet speech is not learned as noise and gain remains bounded")
let loud = signal.process(tone(amplitude: 0.9), boost: true)
expect(loud.samples.allSatisfy { abs($0) <= 0.98 }, "a sudden loud speaker after weak speech does not clip")
var unboosted = MicrophoneSignalProcessor()
expect(unboosted.process(tone(amplitude: 0.006), boost: false).gain == 1, "pickup boost can be disabled without changing speech detection")
var dc = MicrophoneSignalProcessor()
var dcFrame = dc.process([Float](repeating: 0.2, count: 1_600), boost: false)
for _ in 0..<5 { dcFrame = dc.process([Float](repeating: 0.2, count: 1_600), boost: false) }
expect(dcFrame.rms < 0.00001 && !dcFrame.hasVoice, "microphone DC offset settles instead of keeping speech active")
expect(LanguageDetector.detect("Bonjour, je suis étudiant en informatique à l'université de Poitiers.") == .fr, "French accents and ordinary speech remain accepted")
expect(LanguageDetector.detect("我在法国学习计算机。") == .zh, "Chinese speech remains accepted")
expect(LanguageDetector.detect("Привет, как дела?") == nil, "Cyrillic hypotheses are not labeled as French")
expect(LanguageDetector.detect("مرحبا بك") == nil, "Arabic hypotheses are rejected")
expect(LanguageDetector.detect("こんにちは、ありがとう。") == nil, "Japanese hypotheses are rejected")
expect(LanguageDetector.detect("안녕하세요") == nil, "Korean hypotheses are rejected")
expect(LanguageDetector.approvedText("<|ru|>Спасибо.").isEmpty, "foreign-language progress never appears as a live original")
expect(LanguageDetector.detect("This is an English sentence about studying computer science.") == nil, "confident English hypotheses are rejected")
expect(LanguageDetector.detect("Dies ist ein deutscher Satz über das Studium an der Universität.") == nil, "confident German hypotheses are rejected")

assembler.reset()
let overshooting = [word("Bonjour.", 0.1, 30)]
let boundedSentence = assembler.update(words: overshooting, silenceDuration: 0.8, audioEnd: 1.5)
expect(boundedSentence.last?.end == 1.5 && assembler.consumedThrough == 1.5, "word timing cannot move the audio cursor into a future recording")
expect(assembler.update(words: [word("Merci.", 1.6, 2.1)], silenceDuration: 0.8, audioEnd: 2.5).count == 1, "recognition continues immediately after an oversized timestamp")
expect(word("Impossible.", 30, 31).bounded(from: 0, to: 2) == nil, "entirely future word timing is discarded")
expect(word("Invalid.", .nan, 1).bounded(from: 0, to: 2) == nil, "invalid timestamps cannot crash audio slicing")
assembler.reset()
let foreignThenFrench = [word("Спасибо.", 0, 1), word(" Bonjour.", 1.2, 2)]
expect(assembler.update(words: foreignThenFrench, silenceDuration: 0.8, audioEnd: 2.5).map(\.original) == ["Bonjour."], "rejected foreign speech cannot block the next French sentence")

expect(PhraseTranslator.translate("Merci.", from: .fr) == "谢谢。", "standalone thanks receives immediate Chinese without an empty network reply")
expect(PhraseTranslator.translate("Merci !", from: .fr) == "谢谢！", "short phrase keeps its exclamation")
expect(PhraseTranslator.translate("是的？", from: .zh) == "Oui ?", "short Chinese question keeps its question mark")
expect(PhraseTranslator.translate("Merci pour votre aide.", from: .fr) == nil, "longer sentences never use a partial dictionary match")
expect(PhraseTranslator.translate("Merci. Merci.", from: .fr) == nil, "repeated real speech is not reduced to a single acknowledgement")
do {
    let manager = FileManager.default
    let temporary = manager.temporaryDirectory.appendingPathComponent("ZHFR-cache-test-\(UUID())")
    defer { try? manager.removeItem(at: temporary) }
    let root = temporary.appendingPathComponent("ApplicationSupport")
    let legacy = temporary.appendingPathComponent("old-huggingface")
    let cache = LocalModelCache(root: root, legacyRoot: legacy)
    try cache.prepareDirectories()
    let model = cache.folder(for: .fast)
    for component in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
        let directory = model.appendingPathComponent("\(component).mlmodelc")
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("complete fixture weights".utf8).write(to: directory.appendingPathComponent("weight.bin"))
    }
    let unverified = try cache.existingCandidate(for: .fast)
    expect(unverified == model && cache.completedFolder(for: .fast) == nil, "interrupted or unverified model never becomes ready from folder presence")
    do {
        try cache.markCompleted(model, profile: .fast)
        fatalError("Incomplete tokenizer should not receive a completion receipt")
    } catch { expect(error is LocalModelCache.CacheError, "model without tokenizer cannot receive a completion receipt") }
    let tokenizer = cache.tokenizerFolder(for: .fast)
    try manager.createDirectory(at: tokenizer, withIntermediateDirectories: true)
    for filename in ["tokenizer.json", "tokenizer_config.json", "config.json"] {
        try Data("{}".utf8).write(to: tokenizer.appendingPathComponent(filename))
    }
    try cache.markCompleted(model, profile: .fast)
    let cold = LocalModelCache(root: root, legacyRoot: legacy)
    expect(cold.completedFolder(for: .fast) == model, "cold launch reuses a completed model and tokenizer")
    try manager.removeItem(at: tokenizer)
    expect(cold.completedFolder(for: .fast) == model, "completed cache includes its own tokenizer without a shared Hub directory")
    expect(cold.completedFolder(for: .accurate) == nil, "separate model selections do not reuse another model's receipt")
    let relocatedRoot = temporary.appendingPathComponent("new-app-container")
    try manager.copyItem(at: root, to: relocatedRoot)
    let relocated = LocalModelCache(root: relocatedRoot, legacyRoot: legacy)
    expect(relocated.completedFolder(for: .fast) == relocated.folder(for: .fast), "relative receipt remains valid after an app-container move")
    let damaged = model.appendingPathComponent("AudioEncoder.mlmodelc/weight.bin")
    try Data("partial".utf8).write(to: damaged)
    let invalidCandidate = try cold.existingCandidate(for: .fast)
    expect(cold.completedFolder(for: .fast) == nil && invalidCandidate == nil, "truncated completed weights require repair instead of repeated load failure")
    try cold.prepareRepair(for: .fast)
    expect(!manager.fileExists(atPath: damaged.path) && manager.fileExists(atPath: model.appendingPathComponent("TextDecoder.mlmodelc/weight.bin").path), "repair removes truncated weights and retains intact files")
    let oldModel = legacy.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(RecognitionProfile.fast.modelName)")
    try manager.createDirectory(at: oldModel.deletingLastPathComponent(), withIntermediateDirectories: true)
    try manager.copyItem(at: relocated.folder(for: .fast), to: oldModel)
    try manager.removeItem(at: oldModel.appendingPathComponent(".zhfr-complete.json"))
    let migrated = LocalModelCache(root: temporary.appendingPathComponent("migrated"), legacyRoot: legacy)
    try migrated.prepareDirectories()
    let reused = try migrated.existingCandidate(for: .fast)
    expect(reused == migrated.folder(for: .fast) && !manager.fileExists(atPath: oldModel.path), "v2.4 model files move into the persistent cache without another weight download")
}
print("\(passed) sentence, translation, display, language, audio and model-cache regression checks passed.")
