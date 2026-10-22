import Foundation

/// Turns a natural-language question into an FTS5 MATCH expression.
///
/// The index is plain `unicode61` FTS5: no query parser is exposed to the user, so
/// every term is quoted and the strategy (OR / AND / prefix) is chosen here. That
/// keeps user input from being interpreted as FTS5 syntax (a bare `"` or `*` in a
/// question would otherwise raise a SQL error at runtime).
public struct QueryTerms: Equatable {
    public let original: String
    public let terms: [String]
    public let dropped: [String]

    public static let stopwords: Set<String> = [
        "a", "about", "above", "after", "again", "against", "all", "am", "an", "and", "any", "are",
        "as", "at", "be", "because", "been", "before", "being", "below", "between", "both", "but",
        "by", "can", "cannot", "could", "did", "do", "does", "doing", "don", "down", "during", "each",
        "few", "for", "from", "further", "had", "has", "have", "having", "he", "her", "here", "hers",
        "herself", "him", "himself", "his", "how", "i", "if", "in", "into", "is", "it", "its", "itself",
        "just", "me", "more", "most", "my", "myself", "no", "nor", "not", "now", "of", "off", "on",
        "once", "only", "or", "other", "our", "ours", "ourselves", "out", "over", "own", "same", "she",
        "should", "so", "some", "such", "than", "that", "the", "their", "theirs", "them", "themselves",
        "then", "there", "these", "they", "this", "those", "through", "to", "too", "under", "until",
        "up", "very", "was", "we", "were", "what", "when", "where", "which", "while", "who", "whom",
        "why", "will", "with", "would", "you", "your", "yours", "yourself", "yourselves",
        "explain", "describe", "tell", "give", "list", "summary", "summarize", "define", "definition",
        "mean", "means", "meaning", "work", "works", "difference", "differences", "compare", "versus",
        "vs", "between", "why", "how", "does", "did", "please",
    ]

    public init(_ query: String, customStopwords: Set<String> = []) {
        self.original = query
        let raw = TextUtil.words(query)
        var kept: [String] = []
        var dropped: [String] = []
        for word in raw {
            let w = word.count > 3 && word.hasSuffix("s") && !word.hasSuffix("ss") ? String(word.dropLast()) : word
            if w.count < 2 {
                dropped.append(word)
                continue
            }
            if Self.stopwords.contains(w) || customStopwords.contains(w) {
                dropped.append(word)
                continue
            }
            if !kept.contains(w) { kept.append(w) }
        }
        self.terms = kept
        self.dropped = dropped
    }

    public var isEmpty: Bool { terms.isEmpty }

    /// FTS5 expression: quoted terms joined by `op`, each optionally prefix-matched.
    public func expression(op: String = "OR", prefixMatch: Bool = false, minimumPrefixLength: Int = 5) -> String {
        guard !terms.isEmpty else { return "" }
        let parts = terms.map { term -> String in
            let escaped = term.replacingOccurrences(of: "\"", with: "\"\"")
            if prefixMatch && term.count >= minimumPrefixLength {
                return "\"\(escaped)\"*"
            }
            return "\"\(escaped)\""
        }
        return parts.joined(separator: " \(op) ")
    }

    /// Progressively looser strategies, best first. The retriever walks this list
    /// until a query returns hits, so a single rare word never yields nothing.
    public func strategies() -> [(name: String, expression: String)] {
        guard !terms.isEmpty else { return [] }
        var out: [(String, String)] = []
        if terms.count >= 2 {
            out.append(("and-prefix", expression(op: "AND", prefixMatch: true)))
            out.append(("and", expression(op: "AND")))
        }
        out.append(("or-prefix", expression(op: "OR", prefixMatch: true)))
        out.append(("or", expression(op: "OR")))
        return out
    }

    /// Terms weighted for the lexical reranker: title hits and early terms count more.
    public var weightedTerms: [(term: String, weight: Double)] {
        let n = Double(max(1, terms.count))
        return terms.enumerated().map { index, term in
            (term, 1.0 + (n - Double(index)) / n)
        }
    }
}
