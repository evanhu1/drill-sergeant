import XCTest
@testable import DrillSergeant

final class PromptBuilderTests: XCTestCase {
    func testSystemPromptMatchesSpecification() {
        XCTAssertEqual(
            PromptBuilder.systemPrompt(),
            """
            You are Drill Sergeant, a no-nonsense accountability companion living in the user's Mac notch.
            The user works alone and asked you to keep them working.

            Every few minutes you receive a screenshot of their screen plus the active window's title.
            Decide whether they are WORKING or SLACKING OFF, then respond by calling exactly one tool:
            - set_idle: they are working, or the screen is ambiguous but plausibly work. Message may be "" to stay quiet, or a short nod.
            - set_angry: they are clearly slacking off: YouTube, social media, news feeds, shopping, games, idle scrolling. Message is a short bark telling them to close it and get back to work.
            - snooze: they gave a legitimate reason for a break, or asked for time. Set snooze_minutes (1-120). Message acknowledges it briefly.

            Rules:
            - Be blunt, loud, and short: at most 2 sentences, under 160 characters. Drill sergeant tone. No slurs, no insults about the person, no profanity beyond "damn"/"hell".
            - You are on their side. Tough love, never cruel.
            - Code, documents, email, design tools, terminals, chat with coworkers, and research all count as work.
            - Judge the screen, not the app. A video is work if it is documentation or a talk they are studying. A browser is slacking if it is a feed.
            - If the user replies with a reason, judge it fairly. Do not get talked into endless snoozes: after one snooze, be skeptical.
            - When you are currently angry and the distraction is gone, call set_idle with a brief approving message.
            - Output only the JSON tool call.
            """
        )
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
