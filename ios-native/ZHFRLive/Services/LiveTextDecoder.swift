import Accelerate
import ArgmaxCore
import CoreML
import WhisperKit

/// Keep model inference and word alignment in WhisperKit. Sample a bounded
/// greedy pass directly from the logits, avoiding per-token MLTensor dispatch.
final class LiveTextDecoder: TextDecoding {
    private var base: any TextDecoding
    init(wrapping base: any TextDecoding) { self.base = base }
    var tokenizer: WhisperTokenizer? {
        get { base.tokenizer }
        set { base.tokenizer = newValue }
    }
    var isModelMultilingual: Bool {
        get { base.isModelMultilingual }
        set { base.isModelMultilingual = newValue }
    }
    var logitsFilters: [any LogitsFiltering]? {
        get { base.logitsFilters }
        set { base.logitsFilters = newValue }
    }
    var supportsWordTimestamps: Bool { base.supportsWordTimestamps }
    var logitsSize: Int? { base.logitsSize }
    var kvCacheEmbedDim: Int? { base.kvCacheEmbedDim }
    var kvCacheMaxSequenceLength: Int? { base.kvCacheMaxSequenceLength }
    var windowSize: Int? { base.windowSize }
    var embedSize: Int? { base.embedSize }
    func predictLogits(_ inputs: any TextDecoderInputType) async throws -> TextDecoderOutputType? {
        try await base.predictLogits(inputs)
    }
    func prepareDecoderInputs(withPrompt prompt: [Int]) throws -> any DecodingInputsType {
        try base.prepareDecoderInputs(withPrompt: prompt)
    }
    func prefillDecoderInputs(_ inputs: any DecodingInputsType, withOptions options: DecodingOptions?) async throws -> any DecodingInputsType {
        try await base.prefillDecoderInputs(inputs, withOptions: options)
    }
    func decodeText(from encoderOutput: any AudioEncoderOutputType, using inputs: any DecodingInputsType,
                    sampler: TokenSampling, options: DecodingOptions,
                    callback: TranscriptionCallback?) async throws -> DecodingResult {
        guard let tokenizer else { throw WhisperError.tokenizerUnavailable() }
        let selected: any TokenSampling = options.temperature == 0
            ? LiveGreedyTokenSampler(endToken: tokenizer.specialTokens.endToken) : sampler
        return try await base.decodeText(from: encoderOutput, using: inputs, sampler: selected, options: options, callback: callback)
    }
    func detectLanguage(from encoderOutput: any AudioEncoderOutputType, using inputs: any DecodingInputsType,
                        sampler: TokenSampling, options: DecodingOptions, temperature: FloatType) async throws -> DecodingResult {
        guard let tokenizer else { throw WhisperError.tokenizerUnavailable() }
        let selected: any TokenSampling = temperature == 0
            ? LiveGreedyTokenSampler(endToken: tokenizer.specialTokens.endToken) : sampler
        return try await base.detectLanguage(from: encoderOutput, using: inputs, sampler: selected,
                                             options: options, temperature: temperature)
    }
    static func updateKVCache(keyTensor: MLMultiArray, keySlice: MLMultiArray,
                              valueTensor: MLMultiArray, valueSlice: MLMultiArray, insertAtIndex index: Int) {
        TextDecoder.updateKVCache(keyTensor: keyTensor, keySlice: keySlice,
                                 valueTensor: valueTensor, valueSlice: valueSlice, insertAtIndex: index)
    }
}

struct LiveGreedyTokenSampler: TokenSampling {
    let endToken: Int
    func update(tokens: [Int], logits: MLMultiArray, logProbs: [Float]) async -> SamplingResult {
        let valueCount = logits.count
        var values = [Float](repeating: 0, count: valueCount)
        // Core ML may expose float32 or float16 outputs; respect the actual
        // storage type instead of assuming the platform's FloatType layout.
        if logits.strides.last?.intValue == 1, logits.shape.dropLast().allSatisfy({ $0.intValue == 1 }) {
            values.withUnsafeMutableBufferPointer { output in
                if logits.dataType == .float32 {
                    output.baseAddress!.update(from: logits.dataPointer.assumingMemoryBound(to: Float.self), count: logits.count)
                } else if logits.dataType == .float16 {
                    var inputBuffer = vImage_Buffer(data: logits.dataPointer, height: 1,
                        width: vImagePixelCount(logits.count), rowBytes: logits.count * 2)
                    var outputBuffer = vImage_Buffer(data: output.baseAddress!, height: 1,
                        width: vImagePixelCount(logits.count), rowBytes: logits.count * MemoryLayout<Float>.stride)
                    let status = vImageConvert_Planar16FtoPlanarF(&inputBuffer, &outputBuffer, vImage_Flags(kvImageNoFlags))
                    if status != kvImageNoError {
                        for i in 0..<valueCount { output[i] = logits[i].floatValue }
                    }
                } else {
                    for i in 0..<logits.count { output[i] = logits[i].floatValue }
                }
            }
        } else {
            for i in values.indices { values[i] = logits[i].floatValue }
        }
        var maximum: Float = -.infinity
        var index: vDSP_Length = 0
        vDSP_maxvi(values, 1, &maximum, &index, vDSP_Length(values.count))
        let token = maximum.isFinite ? Int(index) : endToken
        var probability: Float = 0
        if maximum.isFinite {
            var negativeMaximum = -maximum
            var count = Int32(values.count)
            values.withUnsafeMutableBufferPointer { pointer in
                vDSP_vsadd(pointer.baseAddress!, 1, &negativeMaximum, pointer.baseAddress!, 1, vDSP_Length(valueCount))
                vvexpf(pointer.baseAddress!, pointer.baseAddress!, &count)
            }
            var sum: Float = 0
            vDSP_sve(values, 1, &sum, vDSP_Length(values.count))
            probability = -log(max(sum, 1))
        }
        return SamplingResult(tokens: tokens + [token], logProbs: logProbs + [probability], completed: token == endToken)
    }
    func finalize(tokens: [Int], logProbs: [Float]) -> SamplingResult {
        let needsEnd = tokens.last != endToken
        return SamplingResult(tokens: tokens + (needsEnd ? [endToken] : []),
                              logProbs: logProbs + (needsEnd ? [0] : []), completed: true)
    }
}
