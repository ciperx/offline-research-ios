import Foundation
import SwiftUI

/// One rendered chat item.
public struct ChatMessage: Identifiable, Equatable {
    public enum Kind: Equatable {
        case user
        case answer
        case notice
    }

    public let id: UUID
    public let kind: Kind
    public var text: String
    public var citations: [Citation]
    public var stats: GenerationStats?
    public var isStreaming: Bool
    public var errorText: String?
    public var retrievalStrategy: String?

    public init(kind: Kind,
                text: String,
                citations: [Citation] = [],
                stats: GenerationStats? = nil,
                isStreaming: Bool = false,
                errorText: String? = nil,
                retrievalStrategy: String? = nil) {
        self.id = UUID()
        self.kind = kind
        self.text = text
        self.citations = citations
        self.stats = stats
        self.isStreaming = isStreaming
        self.errorText = errorText
        self.retrievalStrategy = retrievalStrategy
    }
}

public struct Citation: Identifiable, Equatable {
    public let id: String
    public let index: Int
    public let title: String
    public let url: String
    public let excerpt: String
    public let score: Double
}

public enum EngineSelection: String, CaseIterable, Identifiable {
    case retrieval
    case model

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .retrieval: return "Retrieval only"
        case .model: return "Local model"
        }
    }
}

@MainActor
public final class AppModel: ObservableObject {

    // MARK: - Published state

    @Published public var messages: [ChatMessage] = []
    @Published public var draft: String = ""
    @Published public var isGenerating: Bool = false
    @Published public var engineSelection: EngineSelection = .retrieval
    @Published public var installedModels: [ModelStore.InstalledModel] = []
    @Published public var selectedFileName: String?
    @Published public var statusLine: String = "Ready"
    @Published public var notice: String?
    @Published public var lastError: String?

    // Settings (persisted).
    @Published public var temperature: Double = 0.6 { didSet { persistSettings() } }
    @Published public var maxTokens: Int = 512 { didSet { persistSettings() } }
    @Published public var documentsToKeep: Int = 3 { didSet { persistSettings() } }
    @Published public var contextLength: Int = 4096 { didSet { persistSettings() } }
    @Published public var useEmbeddingRerank: Bool = false { didSet { persistSettings() } }

    // Diagnostics.
    @Published public private(set) var corpusInfo: [String: String] = [:]
    @Published public private(set) var corpusIntegrity: String = "unknown"
    @Published public private(set) var offlineAttempts: Int = 0
    @Published public private(set) var lastRetrieval: RetrievalService.Result?

    // MARK: - Dependencies

    private let modelStore = ModelStore()
    private var registry: ModelRegistry?
    private var corpusStore: CorpusStore?
    private var retriever: RetrievalService?
    private var engine: LLMEngine?
    private var activeEngineName: String?

    private let settingsKey = "offline-research.settings.v1"
    private var generationTask: Task<Void, Never>?

    public init() {}

    // MARK: - Bootstrap

    /// Loads the bundled corpus + catalog. Called once from the app entry point.
    public func bootstrap() {
        OfflineGuard.install()
        loadSettings()

        guard let modelsURL = Bundle.main.url(forResource: "models", withExtension: "json") else {
            lastError = "models.json missing from the app bundle"
            return
        }
        do {
            registry = try ModelRegistry(bundleURL: modelsURL)
        } catch {
            lastError = error.localizedDescription
        }

        guard let corpusURL = Bundle.main.url(forResource: "corpus", withExtension: "sqlite") else {
            lastError = "corpus.sqlite missing from the app bundle — run `make index`"
            return
        }

        do {
            let store = try CorpusStore(url: corpusURL)
            corpusStore = store
            let reranker: PassageReranking = makeReranker()
            retriever = RetrievalService(store: store, reranker: reranker)
            corpusInfo = try store.metadata()
            corpusInfo["docs"] = String(try store.articleCount())
            corpusInfo["chunks"] = String(try store.chunkCount())
            corpusIntegrity = try store.integrityCheck()
            statusLine = "Corpus: \(corpusInfo["docs"] ?? "0") articles"
        } catch {
            lastError = error.localizedDescription
        }

        refreshInstalledModels()

        if let first = installedModels.first {
            selectedFileName = first.fileName
            engineSelection = .model
        } else {
            engineSelection = .retrieval
            notice = "No GGUF installed. Retrieval-only mode works now; add a model in Settings for full answers."
        }

        if messages.isEmpty {
            messages = [ChatMessage(kind: .notice, text: Self.introText)]
        }

        offlineAttempts = OfflineGuard.attemptCount
    }

    private func makeReranker() -> PassageReranking {
        #if canImport(NaturalLanguage)
        if useEmbeddingRerank {
            let hybrid = HybridReranker()
            if hybrid.isAvailable { return hybrid }
        }
        #endif
        return LexicalReranker()
    }

    public static let introText = """
    Fully offline research. The corpus and the model both live on this device; the app \
    has no network code and blocks HTTP loads at runtime.

    Ask for an explanation, a comparison or a mechanism — not just a fact. Answers cite \
    the bundled passages as [1], [2].
    """

    public static let exampleQuestions = [
        "Why does TCP congestion control shrink its window on loss?",
        "Compare RSA and elliptic-curve cryptography for a mobile app",
        "Explain how FTS5 ranks results with BM25",
        "What limits photovoltaic efficiency in single-junction silicon cells?",
        "How does a Kalman filter differ from a particle filter?",
        "Explain CRISPR-Cas9 off-target effects and how they are reduced",
    ]

    // MARK: - Sending

    public func send(_ raw: String? = nil) {
        let text = (raw ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isGenerating else { return }
        draft = ""
        lastError = nil
        messages.append(ChatMessage(kind: .user, text: text))

        var answer = ChatMessage(kind: .answer, text: "", isStreaming: true)
        messages.append(answer)
        let answerID = answer.id
        isGenerating = true
        statusLine = "Retrieving…"

        generationTask = Task { [weak self] in
            guard let self else { return }
            await self.run(question: text, answerID: answerID)
        }
    }

    private func run(question: String, answerID: UUID) async {
        guard let retriever else {
            finish(answerID: answerID, error: "Retriever unavailable — corpus.sqlite missing")
            return
        }

        let history = messages
            .filter { $0.kind == .user || ($0.kind == .answer && !$0.isStreaming) }
            .dropLast(2)
            .suffix(4)
            .map { ChatTurn(role: $0.kind == .user ? .user : .assistant, content: $0.text) }

        var retrieval: RetrievalService.Result?
        do {
            var config = RetrievalService.Config()
            config.documentsToKeep = max(1, min(6, documentsToKeep))
            retrieval = try retriever.retrieve(question, config: config)
        } catch {
            AppLog.error("retrieval failed: \(error)")
        }
        lastRetrieval = retrieval
        let passages = retrieval?.passages ?? []

        let citations = passages.enumerated().map { index, item in
            Citation(
                id: "\(item.passage.chunkID)",
                index: index + 1,
                title: item.passage.title,
                url: item.passage.url,
                excerpt: TextUtil.truncate(item.passage.text, maxCharacters: 900),
                score: item.finalScore
            )
        }
        update(answerID: answerID) { message in
            message.citations = citations
            message.retrievalStrategy = retrieval?.strategy
        }

        let engine = activeEngine()
        guard let engine else {
            finish(answerID: answerID, error: "No engine available")
            return
        }

        statusLine = engineSelection == .model ? "Thinking…" : "Composing from corpus…"

        var sampling = SamplingConfig()
        sampling.temperature = temperature
        sampling.maxTokens = maxTokens
        let turns = PromptBuilder.messages(
            question: question,
            passages: passages,
            history: history,
            budget: .forContext(contextLength, answerTokens: maxTokens)
        )

        do {
            let stream = engine.stream(turns: turns, sampling: sampling)
            var buffer = ""
            for try await event in stream {
                switch event {
                case .token(let piece):
                    buffer += piece
                    update(answerID: answerID) { $0.text = buffer }
                case .stats(let stats):
                    update(answerID: answerID) { $0.stats = stats }
                }
            }
            update(answerID: answerID) { message in
                message.text = buffer
                message.isStreaming = false
            }
            isGenerating = false
            statusLine = "Ready"
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            finish(answerID: answerID, error: message)
        }
    }

    private func finish(answerID: UUID, error: String) {
        update(answerID: answerID) { message in
            message.isStreaming = false
            message.errorText = error
            if message.text.isEmpty { message.text = "" }
        }
        isGenerating = false
        lastError = error
        statusLine = "Ready"
    }

    public func cancelGeneration() {
        engine?.cancel()
        generationTask?.cancel()
        generationTask = nil
        isGenerating = false
        statusLine = "Cancelled"
        if let last = messages.last, last.isStreaming, last.kind == .answer {
            update(answerID: last.id) { $0.isStreaming = false }
        }
    }

    private func update(answerID: UUID, _ mutate: (inout ChatMessage) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == answerID }) else { return }
        mutate(&messages[index])
    }

    // MARK: - Engines

    private func activeEngine() -> LLMEngine? {
        switch engineSelection {
        case .retrieval:
            guard let corpusStore else { return nil }
            if activeEngineName != EngineSelection.retrieval.rawValue {
                engine = ExtractiveEngine(store: corpusStore, reranker: makeReranker())
                try? engine?.load(config: EngineConfig(modelPath: ""))
                activeEngineName = EngineSelection.retrieval.rawValue
            }
            return engine

        case .model:
            #if NO_LLAMA_ENGINE
            return nil
            #else
            guard let fileName = selectedFileName,
                  let url = modelStore.locate(fileName: fileName) else { return nil }
            if activeEngineName != fileName {
                let llama = LlamaEngine()
                var config = EngineConfig(modelPath: url.path)
                config.contextLength = contextLength
                config.threads = Self.recommendedThreadCount
                do {
                    try llama.load(config: config)
                    engine = llama
                    activeEngineName = fileName
                } catch {
                    lastError = error.localizedDescription
                    return nil
                }
            }
            return engine
            #endif
        }
    }

    public static var recommendedThreadCount: Int {
        // Two performance cores is the sweet spot on iPhone: more threads contend for
        // the same memory bandwidth and tokens/sec goes down, not up.
        min(6, max(2, ProcessInfo.processInfo.activeProcessorCount / 2))
    }

    // MARK: - Models

    public func refreshInstalledModels() {
        try? modelStore.ensureDirectory()
        installedModels = modelStore.installed()
        if selectedFileName == nil { selectedFileName = installedModels.first?.fileName }
    }

    public func importModel(from url: URL) {
        let profile = registry?.profile(fileName: url.lastPathComponent)
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let installed = try self.modelStore.install(from: url, profile: profile)
                await MainActor.run {
                    self.refreshInstalledModels()
                    self.selectedFileName = installed.fileName
                    self.engineSelection = .model
                    self.notice = "Installed \(installed.fileName). First load takes a few seconds."
                }
            } catch {
                await MainActor.run { self.lastError = error.localizedDescription }
            }
        }
    }

    public func deleteModel(_ model: ModelStore.InstalledModel) {
        do {
            try modelStore.remove(model)
            refreshInstalledModels()
            if selectedFileName == model.fileName {
                selectedFileName = installedModels.first?.fileName
                engineSelection = installedModels.isEmpty ? .retrieval : engineSelection
                engine?.unload()
                engine = nil
                activeEngineName = nil
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func profile(for file: String) -> ModelProfile? { registry?.profile(fileName: file) }
    public var catalog: [ModelProfile] { registry?.all ?? [] }
    public var modelsDirectoryPath: String { modelStore.directory.path }
    public var documentsPath: String { modelStore.documentsPath() }

    public func selectModel(fileName: String) {
        selectedFileName = fileName
        engineSelection = .model
        engine?.unload()
        engine = nil
        activeEngineName = nil
    }

    public func clearConversation() {
        cancelGeneration()
        messages = [ChatMessage(kind: .notice, text: Self.introText)]
    }

    public func refreshDiagnostics() {
        offlineAttempts = OfflineGuard.attemptCount
        if let corpusStore {
            corpusInfo = (try? corpusStore.metadata()) ?? [:]
            corpusInfo["docs"] = String((try? corpusStore.articleCount()) ?? 0)
            corpusInfo["chunks"] = String((try? corpusStore.chunkCount()) ?? 0)
            corpusIntegrity = (try? corpusStore.integrityCheck()) ?? "unknown"
        }
    }

    // MARK: - Settings

    private struct PersistedSettings: Codable {
        var temperature: Double
        var maxTokens: Int
        var documentsToKeep: Int
        var contextLength: Int
        var useEmbeddingRerank: Bool
    }

    private func persistSettings() {
        let payload = PersistedSettings(
            temperature: temperature,
            maxTokens: maxTokens,
            documentsToKeep: documentsToKeep,
            contextLength: contextLength,
            useEmbeddingRerank: useEmbeddingRerank
        )
        if let data = try? JSONEncoder().encode(payload) {
            UserDefaults.standard.set(data, forKey: settingsKey)
        }
    }

    private func loadSettings() {
        guard let data = UserDefaults.standard.data(forKey: settingsKey),
              let payload = try? JSONDecoder().decode(PersistedSettings.self, from: data) else { return }
        temperature = payload.temperature
        maxTokens = payload.maxTokens
        documentsToKeep = payload.documentsToKeep
        contextLength = payload.contextLength
        useEmbeddingRerank = payload.useEmbeddingRerank
    }
}
