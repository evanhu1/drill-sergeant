import XCTest
@testable import DrillSergeant

final class DecisionTests: XCTestCase {
    func testBuildsDecisionFromNativeToolCallAndAssistantText() throws {
        let decision = try Decision(
            toolCall: call(.set_angry),
            message: "  Close it.  \n"
        )

        XCTAssertEqual(
            decision,
            Decision(tool: .set_angry, snoozeMinutes: nil, message: "Close it.")
        )
    }

    func testMissingSnoozeMinutesDefaultsToTen() throws {
        let decision = try Decision(toolCall: call(.snooze), message: "Ten minutes.")
        XCTAssertEqual(decision.snoozeMinutes, 10)
    }

    func testSnoozeMinutesClampToRange() throws {
        let high = try Decision(
            toolCall: call(.snooze, arguments: .init(minutes: 500)),
            message: "Fine."
        )
        let low = try Decision(
            toolCall: call(.snooze, arguments: .init(minutes: 0)),
            message: "Fine."
        )

        XCTAssertEqual(high.snoozeMinutes, 120)
        XCTAssertEqual(low.snoozeMinutes, 1)
    }

    func testSaveUserPreferenceRequiresText() throws {
        let decision = try Decision(
            toolCall: call(
                .save_user_preference,
                arguments: .init(text: "YouTube tutorials count as work.")
            ),
            message: "Got it."
        )

        XCTAssertEqual(decision.text, "YouTube tutorials count as work.")
        XCTAssertThrowsError(
            try Decision(toolCall: call(.save_user_preference), message: "Got it.")
        )
    }

    func testSetWorkHoursUsesOnlyFunctionArguments() throws {
        let decision = try Decision(
            toolCall: call(
                .set_work_hours,
                arguments: .init(
                    days: [.monday, .tuesday, .wednesday, .thursday, .friday],
                    startTime: "09:00",
                    endTime: "17:00"
                )
            ),
            message: "Weekdays, nine to five."
        )

        XCTAssertEqual(decision.workHours, .standard)
        XCTAssertEqual(decision.message, "Weekdays, nine to five.")
    }

    func testSetWorkHoursRequiresCompleteValidArguments() {
        XCTAssertThrowsError(
            try Decision(
                toolCall: call(
                    .set_work_hours,
                    arguments: .init(days: [.monday], startTime: "09:00")
                ),
                message: "Updated."
            )
        )
        XCTAssertThrowsError(
            try Decision(
                toolCall: call(
                    .set_work_hours,
                    arguments: .init(
                        days: [.monday],
                        startTime: "9am",
                        endTime: "17:00"
                    )
                ),
                message: "Updated."
            )
        )
    }

    func testUnknownNativeToolIsRejected() {
        let unknown = OllamaToolCall(
            function: .init(name: "invented_tool", arguments: .init())
        )
        XCTAssertThrowsError(try Decision(toolCall: unknown, message: ""))
    }

    func testNativeToolDefinitionsHaveIndependentSchemasAndNoMessageArgument() throws {
        XCTAssertEqual(Decision.toolDefinitions.count, 5)
        var names: Set<String> = []

        for definition in Decision.toolDefinitions {
            let function = try XCTUnwrap(definition["function"] as? [String: Any])
            names.insert(try XCTUnwrap(function["name"] as? String))
            let parameters = try XCTUnwrap(function["parameters"] as? [String: Any])
            let properties = try XCTUnwrap(parameters["properties"] as? [String: Any])
            XCTAssertNil(properties["message"])
        }

        XCTAssertEqual(names, Set(Tool.allCasesForTests.map(\.rawValue)))
        let workHours = try definition(named: Tool.set_work_hours.rawValue)
        let parameters = try XCTUnwrap(workHours["parameters"] as? [String: Any])
        XCTAssertEqual(
            parameters["required"] as? [String],
            ["days", "start_time", "end_time"]
        )
    }

    /// A check may only set_idle, set_angry, or snooze. Offering the reply-only tools
    /// there spends prompt tokens on actions `decisionAllowedForCheck` throws away.
    func testCheckToolDefinitionsOfferOnlyTheToolsACheckMayCall() throws {
        var names: Set<String> = []
        for definition in Decision.checkToolDefinitions {
            let function = try XCTUnwrap(definition["function"] as? [String: Any])
            names.insert(try XCTUnwrap(function["name"] as? String))
        }

        XCTAssertEqual(names, ["set_idle", "set_angry", "snooze"])
        XCTAssertFalse(names.contains(Tool.set_work_hours.rawValue))
        XCTAssertFalse(names.contains(Tool.save_user_preference.rawValue))
    }

    private func call(
        _ tool: Tool,
        arguments: OllamaToolArguments = .init()
    ) -> OllamaToolCall {
        OllamaToolCall(function: .init(name: tool.rawValue, arguments: arguments))
    }

    private func definition(named name: String) throws -> [String: Any] {
        for definition in Decision.toolDefinitions {
            guard let function = definition["function"] as? [String: Any],
                  function["name"] as? String == name else {
                continue
            }
            return function
        }
        throw XCTSkip("Missing tool definition \(name)")
    }
}

private extension Tool {
    static let allCasesForTests: [Tool] = [
        .set_idle,
        .snooze,
        .set_angry,
        .save_user_preference,
        .set_work_hours,
    ]
}
