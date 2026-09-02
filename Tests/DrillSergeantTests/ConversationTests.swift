import XCTest
@testable import DrillSergeant

@MainActor
final class ConversationTests: XCTestCase {
    func testImageIsKeptOnlyOnMostRecentUserTurn() {
        let conversation = Conversation()
        conversation.appendUser("first", image: "image-one")
        conversation.appendModelExchange(nativeExchange())
        conversation.appendUser("second", image: "image-two")

        XCTAssertNil(conversation.turns[0].images)
        XCTAssertNil(conversation.turns[1].images)
        XCTAssertNil(conversation.turns[2].images)
        XCTAssertEqual(conversation.turns[3].images, ["image-two"])
    }

    func testMaxTurnsTrimsOldestMessages() {
        let conversation = Conversation(maxTurns: 3)
        conversation.appendUser("one", image: nil)
        conversation.appendModelExchange(nativeExchange(message: "one"))
        conversation.appendUser("two", image: nil)
        conversation.appendModelExchange(nativeExchange(message: "two"))

        XCTAssertEqual(conversation.turns.count, 3)
        XCTAssertNotEqual(conversation.turns.first?.role, "tool")
        XCTAssertTrue(conversation.turns.contains { message in
            message.role == "assistant" && message.content == "two"
        })
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

    func testTrimmingNeverLeavesAnOrphanedToolResult() {
        let conversation = Conversation(maxTurns: 1)

        conversation.appendModelExchange(nativeExchange())

        XCTAssertNotEqual(conversation.turns.first?.role, "tool")
    }

    private func nativeExchange(message: String = "") -> [OllamaMessage] {
        let call = OllamaToolCall(
            function: .init(name: Tool.set_idle.rawValue, arguments: .init())
        )
        return [
            OllamaMessage(
                role: "assistant",
                content: message,
                toolCalls: [call]
            ),
            OllamaMessage(role: "tool", content: "Accepted.", toolName: Tool.set_idle.rawValue),
        ]
    }
}
