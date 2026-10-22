import Foundation

/// Builds the retrieval-augmented prompt.
///
/// Hard rules baked in here rather than in the system prompt alone:
///  * sources are numbered and the model is told to cite them as [n];
///  * the context block is trimmed to a token budget *before* it reaches the model,
///    so a long question on a 4096-token context cannot silently truncate the answer;
///  * the model is instructed to say "not in the corpus" instead of inventing facts,
///    because an offline research tool that hallucinates is worse than one that says
///    it does not know.
public enum PromptBuilder {

    public static let systemPrompt = """
    You are an offline research assistant running entirely on this device. The user has \
    no internet access; you cannot browse, and you must not claim to have looked anything up.

    You are given numbered SOURCES retrieved from a small local corpus, plus the user's \
    question. Answer using them.

    Rules:
    1. Prefer the sources. Cite them inline like [1] or [2][3] after the claim they support.
    2. You may use general knowledge for definitions and for reasoning that the sources \
       support or imply, but mark anything that is not in the sources with "(general knowledge)".
    3. If the sources do not answer the question, say so plainly, then give the best short \
       answer you can and mark it as general knowledge. Never invent citations or URLs.
    4. Be concrete and compact: explain the mechanism, compare the alternatives, give the \
       number or the trade-off. No padding, no restating the question.
    5. Structure longer answers with short paragraphs or a few bullets. No markdown tables.
    """

    public struct Budget {
        public var maxPromptTokens: Int
        public var maxHistoryTokens: Int
        public var maxSourceCharacters: Int

        public init(maxPromptTokens: Int = 2600, maxHistoryTokens: Int = 480, maxSourceCharacters: Int = 6000) {
            self.maxPromptTokens = maxPromptTokens
            self.maxHistoryTokens = maxHistoryTokens
            self.maxSourceCharacters = maxSourceCharacters
        }

        /// Budget for a given context size: leave room for the answer.
        public static func forContext(_ contextLength: Int, answerTokens: Int = 512) -> Budget {
            let prompt = max(512, contextLength - answerTokens - 128)
            return Budget(maxPromptTokens: prompt,
                          maxHistoryTokens: min(600, prompt / 5),
                          maxSourceCharacters: min(8000, prompt * 3))
        }
    }

    public static func messages(question: String,
                                passages: [ScoredPassage],
                                history: [ChatTurn] = [],
                                budget: Budget = Budget()) -> [ChatTurn] {
        var turns: [ChatTurn] = [ChatTurn(role: .system, content: systemPrompt)]

        // History: newest first, walk back until the history budget is spent.
        var historyTurns: [ChatTurn] = []
        var historyTokens = 0
        for turn in history.suffix(8).reversed() {
            let cost = TextUtil.estimatedTokens(turn.content)
            if historyTokens + cost > budget.maxHistoryTokens { break }
            historyTokens += cost
            historyTurns.insert(turn, at: 0)
        }
        turns.append(contentsOf: historyTurns)

        let sourceBlock = sourceSection(passages, budget: budget)
        let userContent: String
        if sourceBlock.isEmpty {
            userContent = """
            SOURCES: (none retrieved — answer from general knowledge and say so)

            QUESTION: \(question)
            """
        } else {
            userContent = """
            SOURCES:
            \(sourceBlock)

            QUESTION: \(question)

            Answer with inline citations where the sources support you.
            """
        }

        // Final guard: if the rendered prompt overflows, drop sources from the tail.
        var included = passages
        var content = userContent
        while TextUtil.estimatedTokens(content) > budget.maxPromptTokens && !included.isEmpty {
            included.removeLast()
            content = rebuild(question: question, passages: included, budget: budget)
        }

        turns.append(ChatTurn(role: .user, content: content))
        return turns
    }

    private static func rebuild(question: String, passages: [ScoredPassage], budget: Budget) -> String {
        let block = sourceSection(passages, budget: budget)
        if block.isEmpty {
            return "SOURCES: (none retrieved — answer from general knowledge and say so)\n\nQUESTION: \(question)"
        }
        return "SOURCES:\n\(block)\n\nQUESTION: \(question)\n\nAnswer with inline citations where the sources support you."
    }

    static func sourceSection(_ passages: [ScoredPassage], budget: Budget) -> String {
        var blocks: [String] = []
        var used = 0
        for (index, item) in passages.enumerated() {
            let body = TextUtil.normalizeWhitespace(item.passage.text)
            let header = "[\(index + 1)] \(item.passage.title)"
            let remaining = budget.maxSourceCharacters - used
            guard remaining > 400 else { break }
            let trimmed = TextUtil.truncate(body, maxCharacters: min(remaining, 1800))
            let block = header + "\n" + trimmed
            blocks.append(block)
            used += block.count + 2
        }
        return blocks.joined(separator: "\n\n")
    }

    /// Trim a generated answer at the first stop sequence.
    public static func truncateAtStop(_ text: String, stops: [String]) -> String {
        var cut = text
        for stop in stops where !stop.isEmpty {
            if let range = cut.range(of: stop) {
                cut = String(cut[..<range.lowerBound])
            }
        }
        return cut
    }
}
