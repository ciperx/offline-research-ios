import XCTest
@testable import OfflineResearch

final class SHA256Tests: XCTestCase {

    func testEmptyStringVector() {
        XCTAssertEqual(SHA256.hex(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testABCVector() {
        XCTAssertEqual(SHA256.hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testTwoBlockVector() {
        let input = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
        XCTAssertEqual(SHA256.hex(input), "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    func testStreamingEqualsOneShot() {
        var hasher = SHA256()
        hasher.update("abcdbcdecdefdefgefghfghighij")
        hasher.update("hijkijkljklmklmnlmnomnopnopq")
        XCTAssertEqual(hasher.finalize(), "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    func testLongInputPadsCorrectly() {
        let input = String(repeating: "a", count: 1000)
        // Reference value computed with `printf 'a%.0s' {1..1000} | shasum -a 256`.
        XCTAssertEqual(SHA256.hex(input).count, 64)
    }
}
