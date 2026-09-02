import XCTest
@testable import DrillSergeant

@MainActor
final class BubbleAffordanceTests: XCTestCase {
    func testOnlyClickUsesPointingHandCursor() {
        XCTAssertTrue(BubbleAffordance.click.usesPointingHandCursor)
        XCTAssertFalse(BubbleAffordance.reply.usesPointingHandCursor)
        XCTAssertFalse(BubbleAffordance.display.usesPointingHandCursor)
    }

    func testAffordanceHintsMatchTheThreeBubbleKinds() {
        XCTAssertEqual(BubbleAffordance.reply.actionHint, "reply ←")
        XCTAssertEqual(BubbleAffordance.click.actionHint, "Next →")
        XCTAssertNil(BubbleAffordance.display.actionHint)
    }

    func testReplyBubbleTapOpensInput() {
        let model = BubbleModel()
        model.affordance = .reply

        model.handleTap()

        XCTAssertTrue(model.isInputOpen)
    }

    func testClickBubbleTapCallsHandlerWithoutOpeningInput() {
        let model = BubbleModel()
        model.affordance = .click
        var tapCount = 0
        model.onTap = { tapCount += 1 }

        model.handleTap()

        XCTAssertEqual(tapCount, 1)
        XCTAssertFalse(model.isInputOpen)
    }

    func testDisplayBubbleTapDoesNothing() {
        let model = BubbleModel()
        model.affordance = .display
        var tapCount = 0
        model.onTap = { tapCount += 1 }

        model.handleTap()

        XCTAssertEqual(tapCount, 0)
        XCTAssertFalse(model.isInputOpen)
    }
}
