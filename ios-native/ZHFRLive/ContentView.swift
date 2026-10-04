import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: InterpreterViewModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    statusCard
                    liveCard
                    transcriptCard
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("中法同传")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("清空") { model.clear() }
                        .disabled(model.lines.isEmpty && model.liveSource.isEmpty)
                }
            }
            .task {
                if !model.whisper.modelReady {
                    await model.prepareModel()
                }
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
            }

            Text(model.whisper.modelStatus)
                .font(.caption)
                .foregroundStyle(.secondary)

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
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
    }

    private var liveCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("实时")
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

            Group {
                Text("原文")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(model.liveSource.isEmpty ? "等待讲话…" : model.liveSource)
                    .font(.title3)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Divider()

                Text("译文")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(model.liveTranslation.isEmpty ? "等待实时译文…" : model.liveTranslation)
                    .font(.title2.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
    }

    private var transcriptCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("对话记录")
                .font(.headline)

            if model.lines.isEmpty {
                Text("完成的对话会出现在这里。")
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
                        Text(line.translation)
                            .font(.body.weight(.medium))
                    }
                    .padding(.vertical, 6)
                    if line.id != model.lines.last?.id {
                        Divider()
                    }
                }
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
    }
}
