import SwiftUI
import UniformTypeIdentifiers

public struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showImporter = false
    @State private var copied = false

    public init() {}

    private var ggufType: UTType {
        UTType(filenameExtension: "gguf") ?? .data
    }

    public var body: some View {
        NavigationStack {
            Form {
                engineSection
                modelsSection
                catalogSection
                retrievalSection
                generationSection
                diagnosticsSection
                aboutSection
            }
            .scrollContentBackground(.hidden)
            .background(Theme.Palette.background)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Theme.Palette.accent)
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [ggufType, .data], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first { model.importModel(from: url) }
                case .failure(let error):
                    model.lastError = error.localizedDescription
                }
            }
            .onAppear { model.refreshDiagnostics() }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Sections

    private var engineSection: some View {
        Section {
            Picker("Engine", selection: $model.engineSelection) {
                ForEach(EngineSelection.allCases) { selection in
                    Text(selection.label).tag(selection)
                }
            }
            .pickerStyle(.segmented)

            if model.engineSelection == .model && model.installedModels.isEmpty {
                Text("No model installed. Install one below, or stay in retrieval-only mode.")
                    .font(Theme.Type.caption)
                    .foregroundStyle(Theme.Palette.warning)
            }
            if let error = model.lastError {
                Text(error)
                    .font(Theme.Type.caption)
                    .foregroundStyle(Theme.Palette.danger)
            }
        } header: {
            Text("Engine")
        } footer: {
            Text("Retrieval-only answers quote the corpus with citations. A local GGUF adds synthesis and reasoning on top of the same passages.")
        }
    }

    private var modelsSection: some View {
        Section {
            ForEach(model.installedModels) { installed in
                Button {
                    model.selectModel(fileName: installed.fileName)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: model.selectedFileName == installed.fileName ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(model.selectedFileName == installed.fileName ? Theme.Palette.accent : Theme.Palette.textTertiary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(installed.displayName)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Theme.Palette.textPrimary)
                            Text(ByteCountFormatter.string(fromByteCount: installed.sizeBytes, countStyle: .file))
                                .font(Theme.Type.caption)
                                .foregroundStyle(Theme.Palette.textTertiary)
                        }
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                .swipeActions {
                    Button(role: .destructive) {
                        model.deleteModel(installed)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }

            Button {
                showImporter = true
            } label: {
                Label("Add model file…", systemImage: "plus.circle")
                    .foregroundStyle(Theme.Palette.accent)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Models folder")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textSecondary)
                Text(model.modelsDirectoryPath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .textSelection(.enabled)
            }
        } header: {
            Text("Installed models")
        } footer: {
            Text("Files are checksum-verified against models.json on import. Nothing is downloaded by the app — see `make model` in the README.")
        }
    }

    private var catalogSection: some View {
        Section {
            ForEach(model.catalog) { profile in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(profile.displayName)
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(Theme.Palette.textPrimary)
                        Spacer()
                        Text(profile.sizeDescription)
                            .font(Theme.Type.caption)
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }
                    Text(profile.notes)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("sha256 \(profile.sha256.prefix(16))… · ctx \(profile.contextTrain) · ~\(profile.ramEstimateMB) MB")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Theme.Palette.textTertiary)
                    Text("make model MODEL=\(profile.id)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Theme.Palette.accent.opacity(0.9))
                        .textSelection(.enabled)
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Catalog (fetch on your Mac, then import)")
        }
    }

    private var retrievalSection: some View {
        Section {
            Stepper(value: $model.documentsToKeep, in: 1...6) {
                HStack {
                    Text("Documents to cite")
                    Spacer()
                    Text("\(model.documentsToKeep)")
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            }
            Toggle("On-device embedding rerank", isOn: $model.useEmbeddingRerank)
            if let info = model.corpusInfo["docs"], let chunks = model.corpusInfo["chunks"] {
                HStack {
                    Text("Corpus")
                    Spacer()
                    Text("\(info) articles · \(chunks) chunks")
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                .font(.system(size: 12))
            }
            if let strategy = model.lastRetrieval?.strategy {
                HStack {
                    Text("Last query plan")
                    Spacer()
                    Text(strategy)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .font(Theme.Type.mono)
                }
            }
        } header: {
            Text("Retrieval")
        } footer: {
            Text("Embedding rerank uses Apple's on-device sentence embeddings (NaturalLanguage). It never leaves the device; toggle it off if recall looks worse for your questions.")
        }
    }

    private var generationSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Temperature")
                    Spacer()
                    Text(String(format: "%.2f", model.temperature))
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .font(Theme.Type.mono)
                }
                Slider(value: $model.temperature, in: 0.0...1.2, step: 0.05)
                    .tint(Theme.Palette.accent)
            }
            Stepper(value: $model.maxTokens, in: 128...1024, step: 64) {
                HStack {
                    Text("Max answer tokens")
                    Spacer()
                    Text("\(model.maxTokens)")
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            }
            Picker("Context", selection: $model.contextLength) {
                Text("2048").tag(2048)
                Text("4096").tag(4096)
                Text("8192").tag(8192)
            }
        } header: {
            Text("Generation")
        } footer: {
            Text("Changing context length reloads the model. 4096 is the default: it holds the system prompt, three passages and a ~500-token answer.")
        }
    }

    private var diagnosticsSection: some View {
        Section {
            row("Offline attempts blocked", "\(model.offlineAttempts)")
            row("Corpus integrity", model.corpusIntegrity)
            row("Schema", model.corpusInfo["schema_version"] ?? "—")
            row("Threads", "\(AppModel.recommendedThreadCount)")
            row("Physical memory", ByteCountFormatter.string(fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .memory))
            Button {
                UIPasteboard.general.string = diagnosticsText
                copied = true
            } label: {
                Label(copied ? "Copied" : "Copy diagnostics", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(Theme.Palette.accent)
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("Offline attempts should stay at 0. If it ever moves, something tried to reach the network and was blocked — the log line is in the console.")
        }
    }

    private var aboutSection: some View {
        Section {
            row("Version", Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
            row("Model license", "Apache-2.0 (Qwen2.5 / SmolLM2)")
            row("Corpus license", "CC BY-SA 4.0 (English Wikipedia)")
            Text("github.com/ciperx/offline-research-ios")
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Theme.Palette.textTertiary)
                .textSelection(.enabled)
        } header: {
            Text("About")
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13))
            Spacer()
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.Palette.textSecondary)
        }
    }

    private var diagnosticsText: String {
        var lines = ["Offline Research iOS diagnostics"]
        lines.append("engine: \(model.engineSelection.rawValue)")
        lines.append("selected model: \(model.selectedFileName ?? "none")")
        lines.append("installed: \(model.installedModels.map(\.fileName).joined(separator: ", "))")
        lines.append("offline attempts: \(model.offlineAttempts)")
        lines.append("corpus docs: \(model.corpusInfo["docs"] ?? "?") chunks: \(model.corpusInfo["chunks"] ?? "?")")
        lines.append("integrity: \(model.corpusIntegrity)")
        lines.append("threads: \(AppModel.recommendedThreadCount)")
        lines.append("context: \(model.contextLength) maxTokens: \(model.maxTokens) temp: \(model.temperature)")
        if let stats = model.messages.last(where: { $0.stats != nil })?.stats {
            lines.append(String(format: "last run: %.1f tok/s, %d tokens, first token %.2fs", stats.tokensPerSecond, stats.generatedTokens, stats.firstTokenSeconds))
        }
        return lines.joined(separator: "\n")
    }
}
