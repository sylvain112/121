import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = ""
    @State private var saveMessage = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("OpenAI API") {
                    SecureField("sk-…", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle("优先使用个人 API", isOn: $settings.usePersonalAPI)
                    Text("API Key 仅保存在本机 iOS Keychain。填写后，实时翻译与 AI 总结优先直接使用你的 API；留空则实时翻译继续使用现有服务器临时密钥。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("保存 API Key") {
                        do {
                            try settings.saveAPIKey(apiKey)
                            saveMessage = apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "已删除个人 API Key" : "已安全保存到 Keychain"
                        } catch {
                            saveMessage = "保存失败：\(error.localizedDescription)"
                        }
                    }
                    if !saveMessage.isEmpty {
                        Text(saveMessage)
                            .font(.caption)
                            .foregroundStyle(saveMessage.contains("失败") ? .red : .green)
                    }
                }

                Section("AI 总结") {
                    TextField("模型", text: $settings.summaryModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("默认使用 gpt-6-astra。你也可以改成自己 API 账户可用的其他文本模型。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear {
                apiKey = settings.apiKeyForEditing()
            }
        }
    }
}
