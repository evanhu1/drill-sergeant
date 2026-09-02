import XCTest
@testable import DrillSergeant

final class RuntimeProfileTests: XCTestCase {
    func testEightGigabytesUsesLowMemoryProfile() {
        let profile = RuntimeProfile.forPhysicalMemory(8 * 1_024 * 1_024 * 1_024)

        XCTAssertEqual(profile, .lowMemory)
        XCTAssertEqual(profile.contextTokens, 4_096)
        XCTAssertEqual(profile.screenshotMaxEdge, 960)
        XCTAssertEqual(profile.conversationMaxTurns, 4)
        XCTAssertEqual(profile.keepAlive, "30s")
        XCTAssertTrue(profile.unloadAfterDecision)
    }

    func testMoreThanEightGigabytesUsesStandardProfile() {
        let profile = RuntimeProfile.forPhysicalMemory(
            8 * 1_024 * 1_024 * 1_024 + 1
        )

        XCTAssertEqual(profile, .standard)
    }
}
