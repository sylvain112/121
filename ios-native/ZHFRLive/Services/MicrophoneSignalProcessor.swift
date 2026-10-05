import Foundation

/// Detect speech on unamplified audio. Gain is bounded and peak-limited, so
/// quiet-room noise cannot become speech just because pickup boost is enabled.
struct MicrophoneSignalProcessor {
    struct Frame {
        let samples: [Float]
        let rms: Float
        let hasVoice: Bool
        let gain: Float
    }
    private var noiseFloor: Float = 0.0003
    private var gain: Float = 1
    private var previousInput: Float = 0
    private var previousOutput: Float = 0

    mutating func process(_ input: [Float], boost: Bool) -> Frame {
        guard !input.isEmpty else { return Frame(samples: [], rms: 0, hasVoice: false, gain: gain) }
        let filtered = input.map { sample -> Float in
            let value = sample - previousInput + 0.995 * previousOutput
            previousInput = sample
            previousOutput = value
            return value
        }
        let rms = sqrt(filtered.reduce(Float(0)) { $0 + $1 * $1 } / Float(filtered.count))
        let hasVoice = rms >= max(0.0012, noiseFloor * 2.2)
        if !hasVoice { noiseFloor = max(0.0001, noiseFloor * 0.95 + rms * 0.05) }
        let peak = filtered.reduce(Float(0)) { max($0, abs($1)) }
        let requested: Float = boost && hasVoice ? min(4, max(1, 0.045 / max(rms, 0.0001))) : 1
        let target = min(requested, 0.95 / max(peak, 0.0001))
        let initial = min(gain, 0.95 / max(peak, 0.0001))
        gain = min(initial * 0.65 + target * 0.35, 4)
        let count = Float(filtered.count)
        let samples = filtered.enumerated().map { index, value -> Float in
            let interpolated = initial + (gain - initial) * Float(index + 1) / count
            return min(0.98, max(-0.98, value * interpolated))
        }
        return Frame(samples: samples, rms: rms, hasVoice: hasVoice, gain: gain)
    }
}
