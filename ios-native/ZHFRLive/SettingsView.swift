import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    var isRecording = false
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = ""
    @State private var saveMessage = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("识别速度") {
                    Picker("本地模型", selection: $settings.recognitionProfile) {
                        ForEach(RecognitionProfile.allCases) { profile in
                            Text(profile.title).tag(profile)
                        }
                    }
                    .pickerStyle(.segmented)
                    Picker("讲话语言", selection: $settings.recognitionLanguage) {
                        ForEach(RecognitionLanguage.allCases) { language in
                            Text(language.title).tag(language)
                        }
                    }
                    Text("只允许中文和法语。仅听法语时选择“法语 → 中文”可省去自动语言检测。快速优先响应；均衡、精准适合更复杂的讲话。切换模型后首次使用需要下载。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .disabled(isRecording)

                Section("收音") {
                    Picker("输入设备", selection: $settings.microphone) {
                        ForEach(MicrophonePreference.allCases) { microphone in
                            Text(microphone.title).tag(microphone)
                        }
                    }
                    Toggle("增强较弱人声", isOn: $settings.pickupBoost)
                    Text("默认优先手机麦克风。使用耳机或外接麦克风时选择跟随系统；主页会显示当前输入设备。")
                        .font(.caption).foregroundStyle(.secondary)
                    if isRecording { Text("结束同传后可调整识别和收音设置。").font(.caption) }
                }
                .disabled(isRecording)

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
