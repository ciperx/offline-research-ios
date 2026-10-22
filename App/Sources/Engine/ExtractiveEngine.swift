import Foundation

/// The no-model engine: retrieval + extractive composition, streamed as if it were a
/// model. Same protocol, same UI path, so the app is fully usable before any GGUF is
/// installed and the two modes can be compared on the same question.
public final class ExtractiveEngine: LLMEngine {

    public let name = "Retrieval (no model)"
    public private(set) var stats = GenerationStats()

    private let store: CorpusStore
    private let retriever: RetrievalService
    private let lock = NSLock()
    private var cancelled = false
    private var loaded = false

    public init(store: CorpusStore, reranker: PassageReranking = LexicalReranker()) {
        self.store = store
        self.retriever = RetrievalService(store: store, reranker: reranker)
    }

    public var isReady: Bool {
        lock.lock(); defer { lock.unlock() }
        return loaded
    }

    public func load(config: EngineConfig) throws {
        lock.lock(); defer { lock.unlock() }
        loaded = true
    }

    public func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
    }

    public func unload() {
        lock.lock(); defer { lock.unlock() }
        loaded = false
    }

    public func stream(turns: [ChatTurn], sampling: SamplingConfig) -> AsyncThrowingStream<EngineEvent, Error> {
        let question = turns.last(where: { $0.role == .user })?.content ?? ""
        let started = Date()

        return AsyncThrowingStream { continuation in
            Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                self.lock.lock()
                self.cancelled = false
                self.lock.unlock()

                do {
                    let retrieval = try self.retriever.retrieve(question)
                    let answer = ExtractiveComposer.compose(
                        query: question,
                        passages: retrieval.passages,
                        maxSentences: max(3, min(6, sampling.maxTokens / 90))
                    )
                    guard !answer.text.isEmpty else {
                        continuation.yield(.token("Nothing in the corpus matched that question. Try different wording, or install a model in Settings to answer from general knowledge."))
                        continuation.finish()
                        return
                    }

                    // Stream in ~4-word groups: matches the cadence of a model on screen
                    // without inventing latency.
                    let words = answer.text.split(separator: " ", omittingEmptySubsequences: false)
                    var buffer: [Substring] = []
                    var firstToken: Double = 0
                    var emitted = 0

                    func flush() {
                        guard !buffer.isEmpty else { return }
                        if firstToken == 0 { firstToken = Date().timeIntervalSince(started) }
                        let text = buffer.joined(separator: " ") + " "
                        continuation.yield(.token(text))
                        emitted += buffer.count
                        buffer.removeAll(keepingCapacity: true)
                    }

                    for word in words {
                        self.lock.lock()
                        let stop = self.cancelled
                        self.lock.unlock()
                        if stop {
                            continuation.finish(throwing: EngineError.cancelled)
                            return
                        }
                        buffer.append(word)
                        if buffer.count >= 4 { flush() }
                    }
                    flush()

                    var final = GenerationStats()
                    final.promptTokens = TextUtil.estimatedTokens(question)
                    final.generatedTokens = emitted
                    final.firstTokenSeconds = firstToken
                    final.tokensPerSecond = emitted > 0 && firstToken > 0
                        ? Double(emitted) / max(0.001, Date().timeIntervalSince(started) - firstToken)
                        : 0
                    final.contextSize = 0
                    self.lock.lock()
                    self.stats = final
                    self.lock.unlock()
                    continuation.yield(.stats(final))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
