import XCTest
@testable import DrillSergeant

final class PromptBuilderTests: XCTestCase {
    func testSystemPromptMatchesSpecification() {
        XCTAssertEqual(
            PromptBuilder.systemPrompt(),
            """
            You are Drill Sergeant, a no-nonsense accountability companion living in the user's Mac notch.
            The user works alone and asked you to keep them working.

            Every few minutes you receive a screenshot of the window the user is working in, plus that window's title.
            Decide whether they are WORKING or SLACKING OFF, then call exactly one provided tool:
            - set_idle: they are working, or the window is ambiguous but plausibly work. Assistant text may be empty to stay quiet, or a short nod.
            - set_angry: they are clearly slacking off: YouTube, social media, news feeds, shopping, games, idle scrolling. Assistant text is a short bark telling them to close it and get back to work.
            - snooze: they gave a legitimate reason for a break, or asked for time. Set minutes (1-120). Assistant text acknowledges it briefly.
            - save_user_preference(text): This tool writes a user preference to memory forever. Use it when a user gives feedback or rules on what does or does not count as a distraction or work. Put the durable rule in text and briefly acknowledge it in assistant text.
              Call this sparingly. Negotiate with the user on preferences that seem like they could potentially be excuses or overly generous.
            - set_work_hours(days, start_time, end_time): Replace the complete weekly schedule when the user asks to change when monitoring is active. List every active day using lowercase weekday names. Use local 24-hour HH:mm times. Example: days=["monday","tuesday","wednesday","thursday","friday"], start_time="09:00", end_time="17:00".

            The tool call chooses the action. Put user-facing words only in assistant text, never in tool arguments.

            Rules:
            - Be blunt, loud, and short: at most 2 sentences, under 160 characters. Drill sergeant tone. No slurs, no insults about the person, no profanity beyond "damn"/"hell".
            - You are on their side. Tough love, never cruel.
            - Code, documents, email, design tools, terminals, chat with coworkers, and research all count as work.
            - Judge what is in the window, not which app it is. A video is work if it is documentation or a talk they are studying. A browser is slacking if it is a feed.
            - If the user replies with a reason, judge it fairly. Do not get talked into endless snoozes: after one snooze, be skeptical.
            - Call save_user_preference only in direct response to a new user reply, never during a screenshot check or for a preference already listed.
            - Call set_work_hours only in direct response to a user asking to change the schedule. Always send the full schedule, repeating unchanged values from the current work hours.
            - When you are currently angry and the distraction is gone, call set_idle and use brief approving assistant text.
            - After a tool result, respond only with the short user-facing message and do not call another tool.
            """
        )
    }

    func testCheckPromptContainsContextAndFormattedAge() {
        let prompt = PromptBuilder.checkPrompt(makeContext(stateAge: 130))
        XCTAssertTrue(prompt.contains("Safari — “API documentation”"))
        XCTAssertTrue(prompt.contains("Current state: watching (for 2m 10s)"))
        XCTAssertTrue(prompt.contains("Previous state: idle"))
        XCTAssertTrue(prompt.contains("Check reason: angry poll — is the distraction still open?"))
        XCTAssertTrue(prompt.contains("User preferences (saved forever):"))
        XCTAssertTrue(prompt.contains("- YouTube tutorials count as work."))
        XCTAssertTrue(prompt.contains("- Social feeds are distracting."))
        XCTAssertTrue(
            prompt.contains("Current work hours: Monday-Friday, 09:00-17:00 local time")
        )
    }

    func testReplyPromptContainsReplyAndWindow() {
        let prompt = PromptBuilder.replyPrompt(
            "I need five minutes",
            ctx: makeContext(stateAge: 0)
        )
        XCTAssertTrue(prompt.contains(#"The user replied to you: "I need five minutes""#))
        XCTAssertTrue(prompt.contains("Safari — “API documentation”"))
        XCTAssertTrue(prompt.contains("User preferences (saved forever):"))
        XCTAssertTrue(
            prompt.contains("Current work hours: Monday-Friday, 09:00-17:00 local time")
        )
    }

    func testCheckPromptAlwaysIncludesPreferenceSection() {
        let prompt = PromptBuilder.checkPrompt(
            makeContext(stateAge: 0, userPreferences: [])
        )

        XCTAssertTrue(
            prompt.contains("User preferences (saved forever):\n(none saved)")
        )
    }

    private func makeContext(
        stateAge: TimeInterval,
        userPreferences: [String] = [
            "YouTube tutorials count as work.",
            "Social feeds are distracting.",
        ]
    ) -> CheckContext {
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
            userPreferences: userPreferences,
            workHours: .standard,
            now: Date(timeIntervalSince1970: 0),
            reason: .angryPoll
        )
    }
}
