import Foundation

enum PCMConverter {
    /// WhisperKit live mic buffers are 16 kHz Float mono. Realtime Translation WebSocket expects 24 kHz PCM16 LE.
    static func float16kToPCM16Base64_24k(_ input: [Float]) -> String {
        guard !input.isEmpty else { return "" }

        let outputCount = Int(Double(input.count) * 1.5)
        var data = Data(capacity: outputCount * MemoryLayout<Int16>.size)

        for outIndex in 0..<outputCount {
            let sourcePosition = Double(outIndex) * (16_000.0 / 24_000.0)
            let left = Int(sourcePosition)
            let right = min(left + 1, input.count - 1)
            let fraction = Float(sourcePosition - Double(left))
            let value = input[left] + (input[right] - input[left]) * fraction
            let clamped = max(-1.0, min(1.0, value))
            var sample = Int16(clamped * 32767.0).littleEndian
            withUnsafeBytes(of: &sample) { bytes in
                data.append(contentsOf: bytes)
            }
        }

        return data.base64EncodedString()
    }
}
