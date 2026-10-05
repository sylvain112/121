import Foundation

@MainActor
final class AppSettings: ObservableObject {
    private enum Keys {
        static let apiKey = "openai-api-key"
        static let summaryModel = "zhfr.summary-model"
        static let translationModel = "zhfr.translation-model"
        static let usePersonalAPI = "zhfr.use-personal-api"
        static let recognitionProfile = "zhfr.recognition-profile"
        static let recognitionLanguage = "zhfr.recognition-language"
        static let microphone = "zhfr.microphone"
        static let pickupBoost = "zhfr.pickup-boost"
    }

    @Published private(set) var hasPersonalAPIKey = false
    @Published var translationModel: TranslationModel {
        didSet { UserDefaults.standard.set(translationModel.rawValue, forKey: Keys.translationModel) }
    }
    @Published var summaryModel: String {
        didSet { UserDefaults.standard.set(summaryModel, forKey: Keys.summaryModel) }
    }
    @Published var usePersonalAPI: Bool {
        didSet { UserDefaults.standard.set(usePersonalAPI, forKey: Keys.usePersonalAPI) }
    }
    @Published var recognitionProfile: RecognitionProfile {
        didSet { UserDefaults.standard.set(recognitionProfile.rawValue, forKey: Keys.recognitionProfile) }
    }
    @Published var recognitionLanguage: RecognitionLanguage {
        didSet { UserDefaults.standard.set(recognitionLanguage.rawValue, forKey: Keys.recognitionLanguage) }
    }
    @Published var microphone: MicrophonePreference {
        didSet { UserDefaults.standard.set(microphone.rawValue, forKey: Keys.microphone) }
    }
    @Published var pickupBoost: Bool {
        didSet { UserDefaults.standard.set(pickupBoost, forKey: Keys.pickupBoost) }
    }

    init() {
        translationModel = TranslationModel(rawValue: UserDefaults.standard.string(forKey: Keys.translationModel) ?? "") ?? .economy
        recognitionProfile = RecognitionProfile(rawValue: UserDefaults.standard.string(forKey: Keys.recognitionProfile) ?? "") ?? .fast
        recognitionLanguage = RecognitionLanguage(rawValue: UserDefaults.standard.string(forKey: Keys.recognitionLanguage) ?? "") ?? .automatic
        microphone = MicrophonePreference(rawValue: UserDefaults.standard.string(forKey: Keys.microphone) ?? "") ?? .phone
        pickupBoost = UserDefaults.standard.object(forKey: Keys.pickupBoost) == nil ? true : UserDefaults.standard.bool(forKey: Keys.pickupBoost)
        summaryModel = UserDefaults.standard.string(forKey: Keys.summaryModel) ?? "gpt-6-astra"
        if UserDefaults.standard.object(forKey: Keys.usePersonalAPI) == nil {
            usePersonalAPI = true
        } else {
            usePersonalAPI = UserDefaults.standard.bool(forKey: Keys.usePersonalAPI)
        }
        hasPersonalAPIKey = !(KeychainStore.read(account: Keys.apiKey) ?? "").isEmpty
    }

    func currentAPIKey() -> String? {
        guard usePersonalAPI else { return nil }
        let value = KeychainStore.read(account: Keys.apiKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    func apiKeyForEditing() -> String {
        KeychainStore.read(account: Keys.apiKey) ?? ""
    }

    func saveAPIKey(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KeychainStore.delete(account: Keys.apiKey)
            hasPersonalAPIKey = false
        } else {
            try KeychainStore.save(trimmed, account: Keys.apiKey)
            hasPersonalAPIKey = true
        }
    }
}
