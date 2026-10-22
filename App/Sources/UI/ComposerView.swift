import SwiftUI

public struct ComposerView: View {
    @EnvironmentObject private var model: AppModel
    @FocusState private var focused: Bool

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            Hairline()
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Ask about a mechanism, a comparison, a number…", text: $model.draft, axis: .vertical)
                    .focused($focused)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1...5)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Theme.Palette.surface)
                    )
                    .submitLabel(.send)
                    .onSubmit { model.send() }

                Button {
                    if model.isGenerating {
                        model.cancelGeneration()
                    } else {
                        model.send()
                        focused = false
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(canSend || model.isGenerating ? Theme.Palette.accent : Theme.Palette.surfaceRaised)
                            .frame(width: 36, height: 36)
                        Image(systemName: model.isGenerating ? "stop.fill" : "arrow.up")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(canSend || model.isGenerating ? Theme.Palette.background : Theme.Palette.textTertiary)
                    }
                }
                .buttonStyle(.plain)
                .disabled(!canSend && !model.isGenerating)
            }
            .padding(.horizontal, Theme.Metrics.gutter)
            .padding(.top, 10)
            .padding(.bottom, 6)

            if let notice = model.notice, model.installedModels.isEmpty {
                Text(notice)
                    .font(Theme.Type.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.Metrics.gutter)
                    .padding(.bottom, 8)
            }
        }
        .background(Theme.Palette.background)
    }

    private var canSend: Bool {
        !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !model.isGenerating
    }
}
