import SwiftUI

struct TranscriptSentenceView: View {
    let line: TranscriptLine
    let isRetrying: Bool
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(line.sourceLanguage == .fr ? "法语原文" : "中文原文")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(line.original)
                .font(.subheadline)
                .textSelection(.enabled)
            if !line.translation.isEmpty {
                Text(line.translation)
                    .font(.body.weight(.medium))
                    .textSelection(.enabled)
            } else if line.translationError == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(isRetrying ? "暂未收到译文，正在自动重试…" : "正在翻译…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let message = line.translationError {
                Text(message).font(.caption).foregroundStyle(.red)
                Button("重试这句翻译", action: onRetry).font(.caption.weight(.semibold))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
    }
}

struct TranscriptHistoryView: View {
    @EnvironmentObject private var model: InterpreterViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { reader in
                List(model.lines) { line in
                    TranscriptSentenceView(line: line, isRetrying: model.retryingIDs.contains(line.id)) {
                        model.retryTranslation(line.id)
                    }
                    .id(line.id)
                }
                .onAppear {
                    if let id = model.lines.last?.id { reader.scrollTo(id, anchor: .bottom) }
                }
            }
            .navigationTitle("全部记录 · \(model.lines.count) 句")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
