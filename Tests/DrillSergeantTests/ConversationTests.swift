import XCTest
@testable import DrillSergeant

@MainActor
final class ConversationTests: XCTestCase {
    func testImageIsKeptOnlyOnMostRecentUserTurn() {
        let conversation = Conversation()
        conversation.appendUser("first", image: "image-one")
        conversation.appendAssistant(
            Decision(tool: .set_idle, snoozeMinutes: nil, message: "")
        )
        conversation.appendUser("second", image: "image-two")

        XCTAssertNil(conversation.turns[0].images)
        XCTAssertNil(conversation.turns[1].images)
        XCTAssertEqual(conversation.turns[2].images, ["image-two"])
    }

    func testMaxTurnsTrimsOldestMessages() {
        let conversation = Conversation(maxTurns: 3)
        conversation.appendUser("one", image: nil)
        conversation.appendAssistant(
            Decision(tool: .set_idle, snoozeMinutes: nil, message: "one")
        )
        conversation.appendUser("two", image: nil)
        conversation.appendAssistant(
            Decision(tool: .set_idle, snoozeMinutes: nil, message: "two")
        )

        XCTAssertEqual(conversation.turns.count, 3)
        XCTAssertEqual(conversation.turns.first?.role, "assistant")
        XCTAssertEqual(conversation.turns.last?.content.contains("two"), true)
    }

    func testHumanReplyAndReset() {
        let conversation = Conversation()
        conversation.recordHumanReply("I am reading the docs")

        XCTAssertEqual(conversation.lastUserMessage, "I am reading the docs")
        XCTAssertEqual(conversation.turns.last?.content, "I am reading the docs")

        conversation.reset()
        XCTAssertNil(conversation.lastUserMessage)
        XCTAssertTrue(conversation.turns.isEmpty)
    }
}
