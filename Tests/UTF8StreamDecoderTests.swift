import XCTest
@testable import OfflineResearch

final class UTF8StreamDecoderTests: XCTestCase {

    func testASCIIPassesThroughImmediately() {
        var decoder = UTF8StreamDecoder()
        XCTAssertEqual(decoder.feed(Array("hello".utf8)), "hello")
        XCTAssertEqual(decoder.pendingByteCount, 0)
    }

    func testMultiByteScalarSplitAcrossFeeds() {
        // "€" is E2 82 AC; feed it one byte at a time.
        var decoder = UTF8StreamDecoder()
        XCTAssertEqual(decoder.feed([0xE2]), "")
        XCTAssertEqual(decoder.feed([0x82]), "")
        XCTAssertEqual(decoder.feed([0xAC]), "€")
        XCTAssertEqual(decoder.pendingByteCount, 0)
    }

    func testEmojiSplitAcrossFeeds() {
        let bytes = Array("🚀".utf8) // F0 9F 9A 80
        var decoder = UTF8StreamDecoder()
        XCTAssertEqual(decoder.feed(bytes.prefix(2)), "")
        XCTAssertEqual(decoder.feed(bytes.suffix(2)), "🚀")
    }

    func testMixedContentKeepsTextBeforePartialScalar() {
        var decoder = UTF8StreamDecoder()
        let bytes = Array("aé".utf8)
        XCTAssertEqual(decoder.feed(bytes.prefix(2)), "a")
        XCTAssertEqual(decoder.feed(bytes.suffix(1)), "é")
    }

    func testFlushEmitsReplacementForTruncatedInput() {
        var decoder = UTF8StreamDecoder()
        _ = decoder.feed([0xE2, 0x82])
        XCTAssertEqual(decoder.flush(), "\u{FFFD}")
        XCTAssertEqual(decoder.pendingByteCount, 0)
    }
}
