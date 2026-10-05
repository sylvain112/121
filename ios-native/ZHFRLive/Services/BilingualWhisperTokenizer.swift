import Foundation
import WhisperKit

enum BilingualWhisperConfiguration {
    static func restrict(_ pipeline: WhisperKit) throws {
        guard let tokenizer = pipeline.tokenizer else { throw BilingualWhisperTokenizer.TokenizerError.missingLanguages }
        guard !(tokenizer is BilingualWhisperTokenizer) else { return }
        let bilingual = try BilingualWhisperTokenizer(wrapping: tokenizer)
        pipeline.tokenizer = bilingual
        // DecodingOptions.suppressTokens excludes special-token IDs. A direct
        // filter also prevents foreign language tokens during text generation.
        pipeline.textDecoder.logitsFilters = (pipeline.textDecoder.logitsFilters ?? []) +
            [SuppressTokensFilter(suppressTokens: bilingual.blockedLanguageTokens)]
    }

    static func options(language: RecognitionLanguage, clipStart: Double = 0, final: Bool = false) -> DecodingOptions {
        DecodingOptions(task: .transcribe, language: language.code,
            temperatureFallbackCount: 0, sampleLength: 128,
            usePrefillPrompt: true, detectLanguage: language == .automatic,
            skipSpecialTokens: true, withoutTimestamps: false, wordTimestamps: true,
            clipTimestamps: [Float(max(0, clipStart))], windowClipTime: final ? 0 : 0.15,
            suppressTokens: [], concurrentWorkerCount: 1)
    }
}

/// Restrict the model's language-detection logits, not just the UI label.
/// Vocabulary, timestamps, Chinese/French word splitting and names stay intact.
final class BilingualWhisperTokenizer: WhisperTokenizer {
    private let base: any WhisperTokenizer
    let allLanguageTokens: Set<Int>
    let blockedLanguageTokens: [Int]
    private let frenchToken: Int
    private let chineseToken: Int
    var specialTokens: SpecialTokens { base.specialTokens }

    enum TokenizerError: LocalizedError {
        case missingLanguages
        var errorDescription: String? { "本地模型缺少中文或法语语言标记。" }
    }

    init(wrapping base: any WhisperTokenizer) throws {
        guard let fr = base.convertTokenToId("<|fr|>"), let zh = base.convertTokenToId("<|zh|>"),
              base.allLanguageTokens.contains(fr), base.allLanguageTokens.contains(zh) else {
            throw TokenizerError.missingLanguages
        }
        self.base = base
        frenchToken = fr
        chineseToken = zh
        allLanguageTokens = [fr, zh]
        blockedLanguageTokens = Array(base.allLanguageTokens.subtracting(allLanguageTokens))
    }

    func sourceLanguage(in tokens: [Int]) -> TranscriptLine.SourceLanguage? {
        for token in tokens.prefix(6) {
            if token == frenchToken { return .fr }
            if token == chineseToken { return .zh }
        }
        return nil
    }

    func encode(text: String) -> [Int] { base.encode(text: text) }
    func decode(tokens: [Int]) -> String { base.decode(tokens: tokens) }
    func convertTokenToId(_ token: String) -> Int? { base.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { base.convertIdToToken(id) }
    func splitToWordTokens(tokenIds: [Int]) -> (words: [String], wordTokens: [[Int]]) {
        base.splitToWordTokens(tokenIds: tokenIds)
    }
}
