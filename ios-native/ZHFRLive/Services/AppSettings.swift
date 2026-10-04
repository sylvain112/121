import Foundation

@MainActor
final class AppSettings: ObservableObject {
    private enum Keys {
        static let apiKey = "openai-api-key"
        static let summaryModel = "zhfr.summary-model"
        static let usePersonalAPI = "zhfr.use-personal-api"
    }

    @Published private(set) var hasPersonalAPIKey = false
    @Published var summaryModel: String {
        didSet { UserDefaults.standard.set(summaryModel, forKey: Keys.summaryModel) }
    }
    @Published var usePersonalAPI: Bool {
        didSet { UserDefaults.standard.set(usePersonalAPI, forKey: Keys.usePersonalAPI) }
    }

    init() {
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
