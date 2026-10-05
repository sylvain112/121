import Foundation

enum RecognitionProfile: String, CaseIterable, Identifiable {
    case fast, balanced, accurate
    var id: String { rawValue }
    var title: String {
        switch self { case .fast: return "快速"; case .balanced: return "均衡"; case .accurate: return "Turbo" }
    }
    var modelName: String {
        switch self {
        case .fast: return "openai_whisper-base"
        case .balanced: return "openai_whisper-small"
        case .accurate: return "openai_whisper-large-v3-v20240930_626MB"
        }
    }
    var description: String {
        switch self {
        case .fast: return "Whisper Base · 快速响应"
        case .balanced: return "Whisper Small · 均衡"
        case .accurate: return "Whisper Large v3 Turbo · 约 626 MB"
        }
    }
    var tokenizerName: String {
        switch self {
        case .fast: return "whisper-base"
        case .balanced: return "whisper-small"
        case .accurate: return "whisper-large-v3"
        }
    }
}

enum RecognitionLanguage: String, CaseIterable, Identifiable {
    case automatic, french, chinese
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "仅中法 · 自动"
        case .french: return "法语 → 中文"
        case .chinese: return "中文 → 法语"
        }
    }
    var code: String? {
        switch self { case .automatic: return nil; case .french: return "fr"; case .chinese: return "zh" }
    }
}

enum MicrophonePreference: String, CaseIterable, Identifiable {
    case phone, automatic
    var id: String { rawValue }
    var title: String { self == .phone ? "优先手机麦克风" : "跟随系统 / 外接麦克风" }
}
