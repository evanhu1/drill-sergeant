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
        let reply = "I am reading the docs"
        conversation.recordHumanReply(reply)

        var modelTurns = conversation.turns
        modelTurns[modelTurns.count - 1] = OllamaMessage(
            role: "user",
            content: "The user replied to you: \"\(reply)\"",
            images: nil
        )

        XCTAssertEqual(modelTurns.last?.content, "The user replied to you: \"\(reply)\"")
        XCTAssertEqual(conversation.lastUserMessage, reply)
        XCTAssertEqual(conversation.turns.last?.content, reply)

        conversation.reset()
        XCTAssertNil(conversation.lastUserMessage)
        XCTAssertTrue(conversation.turns.isEmpty)
    }
}
