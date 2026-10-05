import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: InterpreterViewModel
    @State private var showSettings = false
    @State private var summaryExpanded = true
    @State private var showHistory = false

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
                SettingsView(settings: model.settings, isRecording: model.isRunning || model.isChangingState)
            }
            .onChange(of: showSettings) { _, visible in
                if !visible && !model.isRunning && !model.isChangingState {
                    Task { await model.prepareModel() }
                }
            }
            .sheet(isPresented: $showHistory) { TranscriptHistoryView() }
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
            Text("识别范围：\(model.settings.recognitionLanguage.title)")
                .font(.caption)
                .foregroundStyle(.secondary)

            if model.isRunning {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(model.whisper.inputDescription)
                        Spacer()
                        Text("\(Int(model.micLevel * 100))%")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    ProgressView(value: Double(model.micLevel))
                    if model.whisper.isDecoding {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("正在识别…").font(.caption2).foregroundStyle(.secondary)
                        }
                    } else if model.whisper.decodeDuration >= 0.1 {
                        Text("上一段识别耗时 \(model.whisper.decodeDuration, specifier: "%.1f") 秒")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if model.whisper.decodeDuration > 0 {
                        Text("上一段识别耗时 <0.1 秒").font(.caption2).foregroundStyle(.secondary)
                    }
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
            .disabled(model.isChangingState)

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
                Text("同传记录 · 最近 4 句")
                    .font(.headline)
                Spacer()
                if !model.lines.isEmpty {
                    Button("全部 \(model.lines.count) 句") { showHistory = true }
                        .font(.caption.weight(.semibold))
                }
            }
            let hasDraft = !model.liveSource.isEmpty
            let visible = TranscriptWindow.recent(model.lines, hasDraft: hasDraft)
            VStack(alignment: .leading, spacing: 12) {
                if visible.isEmpty && !hasDraft {
                    Text(model.isRunning ? "正在听取讲话，原句和译文会显示在这里…" : "开始同传后，每句原文和译文会成对显示。")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
                ForEach(visible) { line in
                    TranscriptSentenceView(line: line, isRetrying: model.retryingIDs.contains(line.id)) {
                        model.retryTranslation(line.id)
                    }
                    if line.id != visible.last?.id || hasDraft { Divider() }
                }
                if hasDraft {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.detectedLanguage == .zh ? "中文原文 · 识别中" : "法语原文 · 识别中")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(model.liveSource)
                            .font(.subheadline)
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
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
