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
print("\(passed) sentence and translation regression checks passed.")
