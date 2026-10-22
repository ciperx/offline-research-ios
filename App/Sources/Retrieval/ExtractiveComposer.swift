import Foundation

/// Zero-model answer mode.
///
/// When no GGUF is installed (fresh clone, simulator, or a device where the user
/// has not imported a model yet) the app still answers: it composes an extractive
/// summary out of the retrieved passages with maximal-marginal-relevance selection.
/// This is the honest floor the LLM mode has to beat, and it is what makes the app
/// useful the moment it launches.
public enum ExtractiveComposer {

    public struct Answer {
        public let text: String
        public let usedCitations: [Int]
        public let sentences: [String]
    }

    public static func compose(query: String, passages: [ScoredPassage], maxSentences: Int = 6) -> Answer {
        guard !passages.isEmpty else {
            return Answer(text: "No passage in the bundled corpus covers that question.", usedCitations: [], sentences: [])
        }

        let terms = QueryTerms(query)
        let termSet = Set(terms.terms)

        struct Candidate {
            let sentence: String
            let score: Double
            let citation: Int
            let order: Int
            let words: Set<String>
        }

        var candidates: [Candidate] = []
        for (index, item) in passages.enumerated() {
            let sentences = TextUtil.sentences(item.passage.text)
            for (position, sentence) in sentences.enumerated() {
                let wordCount = sentence.split(separator: " ").count
                guard wordCount >= 8, wordCount <= 70 else { continue }
                let words = Set(TextUtil.words(sentence))
                guard !words.isEmpty else { continue }

                let overlap = Double(termSet.intersection(words).count)
                guard overlap > 0 else { continue }
                let coverage = overlap / Double(max(1, termSet.count))
                let lengthPenalty = 1.0 / (1.0 + abs(Double(wordCount) - 26.0) / 40.0)
                let positionBonus = 1.0 / (1.0 + Double(position) * 0.35)
                let titleBonus = termSet.intersection(Set(TextUtil.words(item.passage.title))).isEmpty ? 0.0 : 0.12
                let score = (0.55 * coverage + 0.25 * lengthPenalty + 0.20 * positionBonus + titleBonus) * item.finalScore.squareRoot()

                candidates.append(
                    Candidate(sentence: sentence, score: score, citation: index + 1, order: candidates.count, words: words)
                )
            }
        }

        candidates.sort { $0.score > $1.score }
        guard !candidates.isEmpty else {
            // Everything retrieved was too short to quote; fall back to the passage lead.
            let lead = TextUtil.truncate(TextUtil.normalizeWhitespace(passages[0].passage.text), maxCharacters: 480)
            return Answer(text: lead, usedCitations: [1], sentences: [lead])
        }

        // Maximal marginal relevance: reward relevance, penalise repeating the same words.
        var selected: [Candidate] = []
        var pool = candidates
        let lambda = 0.72
        while selected.count < maxSentences && !pool.isEmpty {
            var bestIndex = 0
            var bestValue = -Double.infinity
            for (index, candidate) in pool.enumerated() {
                var redundancy = 0.0
                for taken in selected {
                    let shared = Double(candidate.words.intersection(taken.words).count)
                    let denom = Double(max(1, candidate.words.count))
                    redundancy = max(redundancy, shared / denom)
                }
                let value = lambda * candidate.score - (1 - lambda) * redundancy
                if value > bestValue {
                    bestValue = value
                    bestIndex = index
                }
            }
            selected.append(pool.remove(at: bestIndex))
        }

        selected.sort { $0.order < $1.order }

        var body = selected.map { candidate in
            "\(candidate.sentence.trimmingCharacters(in: .whitespaces)) [\(candidate.citation)]"
        }.joined(separator: " ")

        body = TextUtil.normalizeWhitespace(body)

        var sources: [Int] = []
        for candidate in selected where !sources.contains(candidate.citation) {
            sources.append(candidate.citation)
        }

        let sourceList = sources.compactMap { index -> String? in
            guard index - 1 < passages.count else { return nil }
            return "[\(index)] \(passages[index - 1].passage.title)"
        }.joined(separator: "  ·  ")

        let header = "Extractive answer (no model loaded — passages quoted from the bundled corpus):\n\n"
        let text = header + body + "\n\nSources: " + sourceList
        return Answer(text: text, usedCitations: sources, sentences: selected.map(\.sentence))
    }
}
