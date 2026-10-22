import Foundation

/// Hybrid retriever: FTS5 candidates -> per-document dedupe -> rerank -> diversity.
///
/// Why this shape: a single-shot FTS query on a phone-sized index returns a handful
/// of good chunks and a long tail of keyword coincidences. Deduping per document and
/// reranking on term coverage removes most of that tail, and keeping two chunks per
/// document gives the model enough context to synthesise instead of parroting one
/// paragraph.
public final class RetrievalService {

    public struct Config {
        public var candidateLimit: Int = 64
        public var documentsToKeep: Int = 3
        public var chunksPerDocument: Int = 2
        public var maxPassageCharacters: Int = 1500
        public var lexicalWeight: Double = 0.35
        public var minimumFinalScore: Double = 0.02

        public init() {}
    }

    public struct Result {
        public let query: String
        public let passages: [ScoredPassage]
        public let strategy: String
        public let candidates: Int
        public let elapsed: TimeInterval

        public var topDocumentTitle: String? { passages.first?.passage.title }
    }

    private let store: CorpusStore
    private let reranker: PassageReranking
    public let config: Config

    public init(store: CorpusStore, reranker: PassageReranking = LexicalReranker(), config: Config = Config()) {
        self.store = store
        self.reranker = reranker
        self.config = config
    }

    public func retrieve(_ query: String, config override: Config? = nil) throws -> Result {
        let started = Date()
        let cfg = override ?? config
        let terms = QueryTerms(query)
        guard !terms.isEmpty else {
            return Result(query: query, passages: [], strategy: "empty", candidates: 0, elapsed: Date().timeIntervalSince(started))
        }

        var raw: [CorpusStore.Passage] = []
        var usedStrategy = ""
        for strategy in terms.strategies() {
            let hits = try store.search(expression: strategy.expression, limit: cfg.candidateLimit)
            if !hits.isEmpty {
                raw = hits
                usedStrategy = strategy.name
                break
            }
        }

        if raw.isEmpty {
            // Last resort: the question may be a single proper noun we cannot match
            // (typo, plural form, hyphenation). Try a title substring lookup.
            let refs = try store.findDocs(titleContaining: terms.terms.first ?? query, limit: 2)
            for ref in refs {
                raw.append(contentsOf: try store.chunks(forDoc: ref.id))
            }
            if !raw.isEmpty { usedStrategy = "title-substring" }
        }

        guard !raw.isEmpty else {
            return Result(query: query, passages: [], strategy: usedStrategy.isEmpty ? "no-hits" : usedStrategy,
                          candidates: 0, elapsed: Date().timeIntervalSince(started))
        }

        let candidateCount = raw.count
        let maxBM25 = raw.map(\.score).max() ?? 1
        let weighted = terms.weightedTerms

        var scored: [ScoredPassage] = raw.map { passage in
            let lexical = reranker.score(passage: passage, terms: weighted)
            let normalized = maxBM25 > 0 ? max(0, min(1, passage.score / maxBM25)) : 0
            let final = (1 - cfg.lexicalWeight) * normalized + cfg.lexicalWeight * lexical
            return ScoredPassage(
                passage: passage,
                bm25Score: passage.score,
                bm25Normalized: normalized,
                lexicalScore: lexical,
                finalScore: final,
                documentRank: 0
            )
        }

        scored.sort { $0.finalScore > $1.finalScore }

        // One document can dominate a keyword query; keep the best chunk per document
        // first, then fill in second chunks only after every chosen document has one.
        var perDocument: [Int: [ScoredPassage]] = [:]
        for item in scored {
            perDocument[item.passage.docID, default: []].append(item)
        }
        let documentOrder = perDocument
            .map { (docID: $0.key, best: $0.value.first!.finalScore) }
            .sorted { $0.best > $1.best }
            .prefix(cfg.documentsToKeep)

        var chosen: [ScoredPassage] = []
        for rank in 0..<cfg.chunksPerDocument {
            for entry in documentOrder {
                guard let best = perDocument[entry.docID], rank < best.count else { continue }
                let item = best[rank]
                let trimmed = TextUtil.truncate(item.passage.text, maxCharacters: cfg.maxPassageCharacters)
                chosen.append(
                    ScoredPassage(
                        passage: CorpusStore.Passage(
                            chunkID: item.passage.chunkID,
                            docID: item.passage.docID,
                            title: item.passage.title,
                            url: item.passage.url,
                            text: trimmed,
                            score: item.passage.score
                        ),
                        bm25Score: item.bm25Score,
                        bm25Normalized: item.bm25Normalized,
                        lexicalScore: item.lexicalScore,
                        finalScore: item.finalScore,
                        documentRank: rank
                    )
                )
            }
        }

        chosen = chosen.filter { $0.finalScore >= cfg.minimumFinalScore }
        return Result(query: query, passages: chosen, strategy: usedStrategy, candidates: candidateCount,
                      elapsed: Date().timeIntervalSince(started))
    }

    /// Numbered context block handed to the model. Numbering matches the citations
    /// the UI shows, so `[2]` in an answer always means the same passage.
    public static func contextBlock(_ passages: [ScoredPassage]) -> String {
        var blocks: [String] = []
        for (index, item) in passages.enumerated() {
            let body = TextUtil.normalizeWhitespace(item.passage.text)
            blocks.append("[\(index + 1)] \(item.passage.title)\n\(body)")
        }
        return blocks.joined(separator: "\n\n")
    }
}
