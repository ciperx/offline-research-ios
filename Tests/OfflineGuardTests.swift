import XCTest
@testable import OfflineResearch

final class OfflineGuardTests: XCTestCase {

    func testInterceptsNetworkSchemes() {
        for scheme in ["http", "https", "ws", "wss"] {
            let request = URLRequest(url: URL(string: "\(scheme)://example.com")!)
            XCTAssertTrue(OfflineGuard.canInit(with: request), "should intercept \(scheme)")
        }
    }

    func testLeavesLocalSchemesAlone() {
        let fileRequest = URLRequest(url: URL(fileURLWithPath: "/tmp/corpus.sqlite"))
        XCTAssertFalse(OfflineGuard.canInit(with: fileRequest))
        let dataRequest = URLRequest(url: URL(string: "data:text/plain,hi")!)
        XCTAssertFalse(OfflineGuard.canInit(with: dataRequest))
    }

    func testInstallIsIdempotent() {
        OfflineGuard.install()
        OfflineGuard.install()
        XCTAssertTrue(OfflineGuard.isInstalled)
    }

    func testAuditCounterStartsEmptyInTests() {
        OfflineGuard.resetAudit()
        XCTAssertEqual(OfflineGuard.attemptCount, 0)
        XCTAssertTrue(OfflineGuard.attempts.isEmpty)
    }
}
