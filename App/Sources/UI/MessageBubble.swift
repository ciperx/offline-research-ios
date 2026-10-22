import SwiftUI

public struct MessageBubble: View {
    public let message: ChatMessage
    public var onTapSources: () -> Void

    public init(message: ChatMessage, onTapSources: @escaping () -> Void) {
        self.message = message
        self.onTapSources = onTapSources
    }

    public var body: some View {
        switch message.kind {
        case .user:
            userBubble
        case .answer:
            answerBlock
        case .notice:
            noticeBlock
        }
    }

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 40)
            Text(message.text)
                .font(Theme.Type.question)
                .foregroundStyle(Theme.Palette.textPrimary)
                .textSelection(.enabled)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Metrics.corner, style: .continuous)
                        .fill(Theme.Palette.accentDim.opacity(0.35))
                )
        }
    }

    private var answerBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            if message.text.isEmpty && message.isStreaming {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).tint(Theme.Palette.accent)
                    Text(message.citations.isEmpty ? "Retrieving…" : "Reading \(message.citations.count) passages…")
                        .font(Theme.Type.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            } else {
                Text(renderedText)
                    .font(Theme.Type.answer)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let errorText = message.errorText {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Palette.warning)
                    Text(errorText)
                        .font(Theme.Type.caption)
                        .foregroundStyle(Theme.Palette.warning)
                }
            }

            if !message.citations.isEmpty {
                Button(action: onTapSources) {
                    HStack(spacing: 6) {
                        ForEach(message.citations.prefix(4)) { citation in
                            Text("[\(citation.index)]")
                                .font(Theme.Type.mono)
                                .foregroundStyle(Theme.Palette.accent)
                        }
                        Text(sourcesLabel)
                            .font(Theme.Type.caption)
                            .foregroundStyle(Theme.Palette.textTertiary)
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Theme.Palette.surface)
                    )
                }
                .buttonStyle(.plain)
            }

            if let stats = message.stats, !message.isStreaming {
                HStack(spacing: 10) {
                    if stats.tokensPerSecond > 0 {
                        label(String(format: "%.1f tok/s", stats.tokensPerSecond))
                    }
                    if stats.generatedTokens > 0 {
                        label("\(stats.generatedTokens) tok")
                    }
                    if stats.firstTokenSeconds > 0 {
                        label(String(format: "first token %.2fs", stats.firstTokenSeconds))
                    }
                    if let strategy = message.retrievalStrategy {
                        label(strategy)
                    }
                }
            }
        }
    }

    private var sourcesLabel: String {
        let titles = message.citations.prefix(2).map(\.title).joined(separator: ", ")
        return message.citations.count > 2 ? "\(titles) +\(message.citations.count - 2)" : titles
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(Theme.Type.caption)
            .foregroundStyle(Theme.Palette.textTertiary)
    }

    private var renderedText: String {
        message.isStreaming ? message.text + " ▍" : message.text
    }

    private var noticeBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message.text)
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineSpacing(3)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Metrics.cornerSmall, style: .continuous)
                .fill(Theme.Palette.surface)
        )
    }
}

public struct SourcesSheet: View {
    public let message: ChatMessage
    @Environment(\.dismiss) private var dismiss

    public init(message: ChatMessage) {
        self.message = message
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                Theme.Palette.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Passages retrieved for this answer. Stored on-device; text from English Wikipedia, CC BY-SA 4.0.")
                            .font(Theme.Type.caption)
                            .foregroundStyle(Theme.Palette.textTertiary)

                        ForEach(message.citations) { citation in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text("[\(citation.index)]")
                                        .font(Theme.Type.mono)
                                        .foregroundStyle(Theme.Palette.accent)
                                    Text(citation.title)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(Theme.Palette.textPrimary)
                                    Spacer()
                                    Text(String(format: "%.3f", citation.score))
                                        .font(Theme.Type.mono)
                                        .foregroundStyle(Theme.Palette.textTertiary)
                                }
                                Text(citation.excerpt)
                                    .font(.system(size: 13.5))
                                    .foregroundStyle(Theme.Palette.textSecondary)
                                    .lineSpacing(3)
                                Text(citation.url)
                                    .font(Theme.Type.mono)
                                    .foregroundStyle(Theme.Palette.textTertiary)
                            }
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.Metrics.cornerSmall, style: .continuous)
                                    .fill(Theme.Palette.surface)
                            )
                        }
                    }
                    .padding(Theme.Metrics.gutter)
                }
            }
            .navigationTitle("Sources")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Theme.Palette.accent)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
