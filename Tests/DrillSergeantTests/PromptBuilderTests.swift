import XCTest
@testable import DrillSergeant

final class PromptBuilderTests: XCTestCase {
    func testSystemPromptContainsGoal() {
        let prompt = PromptBuilder.systemPrompt(goal: "Ship the macOS app")
        XCTAssertTrue(prompt.contains("Ship the macOS app"))
        XCTAssertTrue(prompt.contains("Output only the JSON tool call."))
    }

    func testCheckPromptContainsContextAndFormattedAge() {
        let prompt = PromptBuilder.checkPrompt(makeContext(stateAge: 130))
        XCTAssertTrue(prompt.contains("Safari — “API documentation”"))
        XCTAssertTrue(prompt.contains("Current state: watching (for 2m 10s)"))
        XCTAssertTrue(prompt.contains("Previous state: idle"))
        XCTAssertTrue(prompt.contains("Check reason: angry poll — is the distraction still open?"))
    }

    func testReplyPromptContainsReplyAndWindow() {
        let prompt = PromptBuilder.replyPrompt(
            "I need five minutes",
            ctx: makeContext(stateAge: 0)
        )
        XCTAssertTrue(prompt.contains(#"The user replied to you: "I need five minutes""#))
        XCTAssertTrue(prompt.contains("Safari — “API documentation”"))
    }

    private func makeContext(stateAge: TimeInterval) -> CheckContext {
        CheckContext(
            goal: "Ship",
            state: .watching,
            previousState: .idle,
            stateAge: stateAge,
            window: ActiveWindowInfo(
                appName: "Safari",
                bundleID: "com.apple.Safari",
                windowTitle: "API documentation"
            ),
            lastUserMessage: nil,
            now: Date(timeIntervalSince1970: 0),
            reason: .angryPoll
        )
    }
}
