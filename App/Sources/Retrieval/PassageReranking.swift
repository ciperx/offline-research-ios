import Foundation

/// A passage plus every score that contributed to its rank. Keeping the parts
/// separate makes the ranking auditable in the diagnostics screen and testable.
public struct ScoredPassage: Equatable {
    public let passage: CorpusStore.Passage
    public let bm25Score: Double
    public let bm25Normalized: Double
    public let lexicalScore: Double
    public let finalScore: Double
    public let documentRank: Int
}

/// Second-stage scoring. The default is lexical (works everywhere, no model);
/// `NaturalLanguageReranker` (iOS only) adds on-device sentence embeddings.
public protocol PassageReranking {
    func score(passage: CorpusStore.Passage, terms: [(term: String, weight: Double)]) -> Double
}

/// Term-coverage scoring: how much of the question the passage actually covers,
/// with title matches weighted double and a bonus for covering every term.
public struct LexicalReranker: PassageReranking {
    public init() {}

    public func score(passage: CorpusStore.Passage, terms: [(term: String, weight: Double)]) -> Double {
        guard !terms.isEmpty else { return 0 }
        let bodyWords = Set(TextUtil.words(passage.text))
        let titleWords = Set(TextUtil.words(passage.title))
        var totalWeight = 0.0
        var earned = 0.0
        var covered = 0

        for (term, weight) in terms {
            totalWeight += weight
            // allow simple suffix variants ("reaction"/"reactions", "bacteri"/"bacteria")
            var hit = false
            if bodyWords.contains(term) { hit = true; earned += weight }
            else if let match = bodyWords.first(where: { $0.hasPrefix(term) && $0.count - term.count <= 3 }) {
                _ = match
                hit = true
                earned += weight * 0.8
            }
            if titleWords.contains(term) {
                hit = true
                earned += weight * 1.0
            }
            if hit { covered += 1 }
        }

        guard totalWeight > 0 else { return 0 }
        var score = earned / (totalWeight * 2.0)     // normalize: body 1.0 + title 1.0
        if covered == terms.count { score += 0.25 }  // full coverage bonus
        return min(1.0, score)
    }
}

#if canImport(NaturalLanguage)
import NaturalLanguage

/// On-device embedding rerank (sentence embeddings shipped with the OS, no network).
/// Falls back to lexical scores when the OS has no sentence embedding for the language.
public final class HybridReranker: PassageReranking {
    private let lexical = LexicalReranker()
    private let embedding: NLEmbedding?

    public init(language: NLLanguage = .english) {
        self.embedding = NLEmbedding.sentenceEmbedding(for: language)
    }

    public var isAvailable: Bool { embedding != nil }

    public func score(passage: CorpusStore.Passage, terms: [(term: String, weight: Double)]) -> Double {
        let lexicalScore = lexical.score(passage: passage, terms: terms)
        guard let embedding else { return lexicalScore }
        let query = terms.map(\.term).joined(separator: " ")
        guard !query.isEmpty else { return lexicalScore }
        let snippet = TextUtil.truncate(passage.text, maxCharacters: 600, ellipsis: "")
        let distance = embedding.distance(between: query, and: snippet) // 0 = identical, 2 = opposite
        let similarity = max(0, min(1, 1 - distance / 2))
        return 0.55 * lexicalScore + 0.45 * similarity
    }
}
#endif
