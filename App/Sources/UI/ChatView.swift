import SwiftUI

public struct ChatView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showSettings = false
    @State private var sourcesForMessage: ChatMessage?

    public init() {}

    public var body: some View {
        NavigationStack {
            ZStack {
                Theme.Palette.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    header
                    Hairline()
                    transcript
                    ComposerView()
                }
            }
            .navigationBarHidden(true)
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .environmentObject(model)
            }
            .sheet(item: $sourcesForMessage) { message in
                SourcesSheet(message: message)
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Offline Research")
                        .font(Theme.Type.title)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text(model.statusLine)
                        .font(Theme.Type.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                Spacer()
                enginePill
                Button {
                    model.clearConversation()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                .padding(.leading, 10)
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                .padding(.leading, 8)
            }
            .padding(.horizontal, Theme.Metrics.gutter)
            .padding(.top, 8)
            .padding(.bottom, 10)
        }
        .background(Theme.Palette.background)
    }

    private var enginePill: some View {
        Button {
            showSettings = true
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(model.engineSelection == .model ? Theme.Palette.accent : Theme.Palette.textTertiary)
                    .frame(width: 6, height: 6)
                Text(model.engineSelection == .model ? (model.selectedFileName.map(shortName) ?? "model") : "retrieval")
                    .font(Theme.Type.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(Theme.Palette.surface)
            )
        }
        .buttonStyle(.plain)
    }

    private func shortName(_ file: String) -> String {
        file.replacingOccurrences(of: ".gguf", with: "")
            .replacingOccurrences(of: "-instruct", with: "")
            .replacingOccurrences(of: "qwen2.5-", with: "qwen")
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(model.messages) { message in
                        MessageBubble(message: message) {
                            if !message.citations.isEmpty { sourcesForMessage = message }
                        }
                        .id(message.id)
                    }

                    if model.messages.count <= 1 {
                        exampleQuestions
                    }

                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, Theme.Metrics.gutter)
                .padding(.top, 18)
                .padding(.bottom, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.messages.count) { _ in
                withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: model.messages.last?.text) { _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    private var exampleQuestions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TRY")
                .font(Theme.Type.sectionHeader)
                .tracking(0.8)
                .foregroundStyle(Theme.Palette.textTertiary)
                .padding(.top, 6)

            ForEach(AppModel.exampleQuestions, id: \.self) { question in
                Button {
                    model.send(question)
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Text(question)
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.Palette.textTertiary)
                            .padding(.top, 3)
                    }
                    .padding(11)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Metrics.cornerSmall, style: .continuous)
                            .fill(Theme.Palette.surface)
                    )
                }
                .buttonStyle(.plain)
            }

            if model.installedModels.isEmpty {
                Text("Retrieval-only mode: answers quote the bundled corpus. Add a GGUF in Settings for synthesised answers.")
                    .font(Theme.Type.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .padding(.top, 4)
            }
        }
    }
}
