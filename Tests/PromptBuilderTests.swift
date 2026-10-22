import XCTest
@testable import OfflineResearch

final class PromptBuilderTests: XCTestCase {

    private func passage(_ title: String, _ text: String, score: Double = 1.0) -> ScoredPassage {
        ScoredPassage(
            passage: CorpusStore.Passage(chunkID: 1, docID: 1, title: title, url: "https://example.invalid", text: text, score: score),
            bm25Score: score,
            bm25Normalized: 1,
            lexicalScore: score,
            finalScore: score,
            documentRank: 0
        )
    }

    func testSourcesAreNumberedAndQuestionFollows() {
        let turns = PromptBuilder.messages(
            question: "Why does TCP back off?",
            passages: [passage("TCP congestion control", "Senders reduce the window on loss.")]
        )
        XCTAssertEqual(turns.first?.role, .system)
        XCTAssertEqual(turns.last?.role, .user)
        let user = turns.last?.content ?? ""
        XCTAssertTrue(user.contains("[1] TCP congestion control"))
        XCTAssertTrue(user.contains("QUESTION: Why does TCP back off?"))
    }

    func testNoSourcesStillProducesUsablePrompt() {
        let turns = PromptBuilder.messages(question: "What is entropy?", passages: [])
        let user = turns.last?.content ?? ""
        XCTAssertTrue(user.contains("none retrieved"))
        XCTAssertTrue(user.contains("What is entropy?"))
    }

    func testBudgetDropsTrailingSources() {
        let long = String(repeating: "word ", count: 400)
        let passages = (1...6).map { passage("Doc \($0)", long) }
        let turns = PromptBuilder.messages(question: "Compare all of these", passages: passages,
                                           budget: PromptBuilder.Budget(maxPromptTokens: 700,
                                                                        maxHistoryTokens: 0,
                                                                        maxSourceCharacters: 6000))
        let user = turns.last?.content ?? ""
        XCTAssertLessThan(TextUtil.estimatedTokens(user), 900)
        XCTAssertFalse(user.contains("[6]"))
    }

    func testHistoryIsTrimmedBeforeSources() {
        let history = (1...10).map { ChatTurn(role: .user, content: String(repeating: "earlier ", count: 40)) }
        let turns = PromptBuilder.messages(question: "q", passages: [passage("Doc", "body")], history: history,
                                           budget: PromptBuilder.Budget(maxPromptTokens: 1200, maxHistoryTokens: 100, maxSourceCharacters: 800))
        XCTAssertLessThanOrEqual(turns.count, 3)
    }

    func testStopSequenceTruncation() {
        let text = "The answer is 42.<|im_end|>garbage"
        XCTAssertEqual(PromptBuilder.truncateAtStop(text, stops: ["<|im_end|>"]), "The answer is 42.")
    }
}
