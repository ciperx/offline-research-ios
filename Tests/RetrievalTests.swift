import XCTest
@testable import OfflineResearch

/// These tests run against the bundled corpus.sqlite, so they also serve as a
/// regression check on the index build (if the file is stale or truncated, they fail).
final class RetrievalTests: XCTestCase {

    private var store: CorpusStore!
    private var retriever: RetrievalService!

    override func setUpWithError() throws {
        let url = try XCTUnwrap(Self.corpusURL(), "corpus.sqlite not found in the test bundle")
        store = try CorpusStore(url: url)
        retriever = RetrievalService(store: store)
    }

    private static func corpusURL() -> URL? {
        let candidates = [
            Bundle(for: RetrievalTests.self).url(forResource: "corpus", withExtension: "sqlite"),
            Bundle.main.url(forResource: "corpus", withExtension: "sqlite"),
        ]
        return candidates.compactMap { $0 }.first
    }

    func testCorpusOpensAndHasContent() throws {
        XCTAssertGreaterThan(try store.articleCount(), 50)
        XCTAssertGreaterThan(try store.chunkCount(), 200)
        XCTAssertEqual(try store.integrityCheck(), "ok")
    }

    func testSearchReturnsRankedPassages() throws {
        let hits = try store.search(expression: "\"congestion\"", limit: 10)
        XCTAssertFalse(hits.isEmpty)
        XCTAssertGreaterThan(hits[0].score, 0)
        XCTAssertEqual(hits[0].title, "TCP congestion control")
    }

    func testRetrievalFindsExpectedDocument() throws {
        let result = try retriever.retrieve("How does TCP congestion control react to packet loss?")
        XCTAssertFalse(result.passages.isEmpty)
        XCTAssertEqual(result.passages.first?.passage.title, "TCP congestion control")
        XCTAssertGreaterThan(result.candidates, 0)
    }

    func testRetrievalCapsDocumentsToKeep() throws {
        var config = RetrievalService.Config()
        config.documentsToKeep = 2
        config.chunksPerDocument = 1
        let result = try retriever.retrieve("How does a Kalman filter combine a prediction with a measurement?", config: config)
        let docIDs = Set(result.passages.map(\.passage.docID))
        XCTAssertLessThanOrEqual(docIDs.count, 2)
    }

    func testEmptyQueryReturnsNothingRatherThanEverything() throws {
        let result = try retriever.retrieve("the and of")
        XCTAssertTrue(result.passages.isEmpty)
        XCTAssertEqual(result.strategy, "empty")
    }

    func testUnknownTopicDoesNotCrash() throws {
        let result = try retriever.retrieve("zzzzqqqq xylophonic quokka")
        XCTAssertTrue(result.passages.isEmpty || result.strategy == "title-substring")
    }

    func testExtractiveComposerCitesPassages() throws {
        let result = try retriever.retrieve("What limits the efficiency of a single junction solar cell?")
        let answer = ExtractiveComposer.compose(query: "What limits the efficiency of a single junction solar cell?",
                                                passages: result.passages)
        XCTAssertFalse(answer.text.isEmpty)
        XCTAssertFalse(answer.usedCitations.isEmpty)
        XCTAssertTrue(answer.text.contains("["))
    }
}
