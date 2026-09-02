import XCTest
@testable import DrillSergeant

final class BubbleAffordanceTests: XCTestCase {
    func testOnlyOnboardingNextUsesPointingHandCursor() {
        XCTAssertTrue(BubbleAffordance.onboardingNext.usesPointingHandCursor)
        XCTAssertFalse(BubbleAffordance.reply.usesPointingHandCursor)
    }
}
