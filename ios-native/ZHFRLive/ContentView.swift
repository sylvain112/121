import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: InterpreterViewModel
    @State private var showSettings = false
    @State private var summaryExpanded = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    statusCard
                    conversationCard
                    actionsCard
                    if !model.summaryText.isEmpty { summaryCard }
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("中法同传")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    Button("清空") { model.clear() }
                        .disabled(model.lines.isEmpty && model.liveSource.isEmpty && model.recognizedText.isEmpty)
                }
            }
            .task {
                if !model.whisper.modelReady {
                    await model.prepareModel()
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(settings: model.settings)
            }
            .sheet(item: $model.exportItem) { item in
                ShareSheet(items: [item.url])
            }
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle()
                    .fill(model.isRunning ? Color.green : Color.secondary)
                    .frame(width: 10, height: 10)
                Text(model.status)
                    .font(.headline)
                Spacer()
                if model.settings.hasPersonalAPIKey && model.settings.usePersonalAPI {
                    Text("个人 API")
                        .font(.caption.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.blue.opacity(0.12), in: Capsule())
                }
            }

            Text(model.whisper.modelStatus)
                .font(.caption)
                .foregroundStyle(.secondary)

            if model.isRunning {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("麦克风输入")
                        Spacer()
                        Text("\(Int(model.micLevel * 100))% · \(model.audioChunkCount) chunks")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    ProgressView(value: Double(model.micLevel))
                }
            }

            Button {
                Task { await model.toggle() }
            } label: {
                HStack {
                    Image(systemName: model.isRunning ? "stop.fill" : "mic.fill")
                    Text(model.isRunning ? "结束同传" : "开始同传")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.isRunning ? .red : .blue)

            if !model.lastError.isEmpty {
                Text(model.lastError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
    }

    private var conversationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("同传记录")
                    .font(.headline)
                Spacer()
                if let language = model.detectedLanguage {
                    Text(language == .zh ? "中文 → Français" : "Français → 中文")
                        .font(.caption.bold())
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(.thinMaterial, in: Capsule())
                }
            }

            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(model.isRunning ? Color.green : Color.secondary)
                                .frame(width: 7, height: 7)
                            Text("实时")
                                .font(.subheadline.bold())
                        }

                        Text("原文 · 本地 Whisper")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(model.liveSource.isEmpty ? "等待讲话…" : model.liveSource)
                            .font(.title3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)

                        Text("译文")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 3)
                        Text(model.liveTranslation.isEmpty ? "等待实时译文…" : model.liveTranslation)
                            .font(.title3.weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }

                    Divider()

                    Text("文字记录")
                        .font(.subheadline.bold())

                    if model.lines.isEmpty {
                        Text("完成的分段记录会出现在这里。上下拖动此区域即可查看全部内容。")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                    } else {
                        ForEach(model.lines) { line in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(line.sourceLanguage == .zh ? "中文 → Français" : "Français → 中文")
                                    .font(.caption.bold())
                                    .foregroundStyle(.secondary)
                                Text(line.original)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                Text(line.translation)
                                    .font(.body.weight(.medium))
                                    .textSelection(.enabled)
                            }
                            .padding(.vertical, 3)

                            if line.id != model.lines.last?.id {
                                Divider()
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 4)
            }
            .frame(height: 480)
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
    }

    private var actionsCard: some View {
        HStack(spacing: 12) {
            Button {
                Task { await model.summarize() }
            } label: {
                Label(model.isSummarizing ? "总结中…" : "AI 总结", systemImage: "sparkles")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isSummarizing || (model.recognizedText.isEmpty && model.lines.isEmpty))

            Button {
                model.prepareTranscriptExport()
            } label: {
                Label("导出识别文本", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(model.recognizedText.isEmpty && model.lines.isEmpty)
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    summaryExpanded.toggle()
                }
            } label: {
                HStack {
                    Text("AI 总结")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: summaryExpanded ? "chevron.up" : "chevron.down")
                        .font(.subheadline.bold())
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(summaryExpanded ? "收起 AI 总结" : "展开 AI 总结")

            if summaryExpanded {
                Divider()
                Text(model.summaryText)
                    .font(.body)
                    .textSelection(.enabled)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
    }
}