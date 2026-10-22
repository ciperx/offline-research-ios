import XCTest
@testable import OfflineResearch

final class ModelCatalogTests: XCTestCase {

    private func registry() throws -> ModelRegistry {
        let url = try XCTUnwrap(Bundle(for: ModelCatalogTests.self).url(forResource: "models", withExtension: "json")
            ?? Bundle.main.url(forResource: "models", withExtension: "json"))
        return try ModelRegistry(bundleURL: url)
    }

    func testCatalogLoadsAndHasDefault() throws {
        let registry = try registry()
        XCTAssertGreaterThanOrEqual(registry.all.count, 3)
        let def = try XCTUnwrap(registry.defaultProfile)
        XCTAssertEqual(def.id, "qwen2.5-1.5b-instruct-q4_k_m")
    }

    func testEveryChecksumIsSixtyFourHexChars() throws {
        for profile in try registry().all {
            XCTAssertEqual(profile.sha256.count, 64, profile.id)
            XCTAssertTrue(profile.sha256.allSatisfy { $0.isHexDigit }, profile.id)
            XCTAssertTrue(profile.url.hasPrefix("https://huggingface.co/"), profile.id)
            XCTAssertGreaterThan(profile.sizeBytes, 100_000_000, profile.id)
        }
    }

    func testRecommendationFitsMemoryBudget() throws {
        let registry = try registry()
        // 4 GB device: the 1.5B Q4 profile (~1.9 GB resident) should still fit, the
        // 1.5B Q8 profile (~2.7 GB) should not be chosen over it.
        let small = try XCTUnwrap(registry.recommended(forPhysicalMemory: 4 * 1024 * 1024 * 1024))
        XCTAssertLessThanOrEqual(small.estimatedResidentMB(contextLength: small.recommendedContext), 2400)
        let large = try XCTUnwrap(registry.recommended(forPhysicalMemory: 12 * 1024 * 1024 * 1024))
        XCTAssertGreaterThanOrEqual(large.sizeBytes, small.sizeBytes)
    }

    func testResidentEstimateGrowsWithContext() throws {
        let profile = try XCTUnwrap(try registry().defaultProfile)
        XCTAssertGreaterThan(profile.estimatedResidentMB(contextLength: 8192),
                             profile.estimatedResidentMB(contextLength: 2048))
    }
}
