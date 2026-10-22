import XCTest
@testable import OfflineResearch

final class QueryTermsTests: XCTestCase {

    func testStopwordsAndQuestionWordsAreDropped() {
        let terms = QueryTerms("How does TCP congestion control react to packet loss?")
        XCTAssertEqual(terms.terms, ["tcp", "congestion", "control", "react", "packet", "loss"])
    }

    func testPluralReduction() {
        XCTAssertEqual(QueryTerms("batteries").terms, ["battery"])
        XCTAssertEqual(QueryTerms("glass").terms, ["glass"])
    }

    func testTermsAreQuotedSoFTSOperatorsCannotLeak() {
        let terms = QueryTerms("photosynthesis AND sugar*")
        for expression in terms.strategies().map(\.expression) {
            XCTAssertFalse(expression.contains("AND sugar*"), "unquoted operator leaked: \(expression)")
        }
    }

    func testEmptyQueryHasNoStrategies() {
        let terms = QueryTerms("the and of")
        XCTAssertTrue(terms.isEmpty)
        XCTAssertTrue(terms.strategies().isEmpty)
    }

    func testStrategyOrderPrefersPrecision() {
        let names = QueryTerms("kalman filter noise").strategies().map(\.name)
        XCTAssertEqual(names.first, "and-prefix")
        XCTAssertEqual(names.last, "or")
    }

    func testSingleTermSkipsAndStrategies() {
        let names = QueryTerms("sourdough").strategies().map(\.name)
        XCTAssertEqual(names, ["or-prefix", "or"])
    }
}
