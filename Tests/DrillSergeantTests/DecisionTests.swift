import XCTest
@testable import DrillSergeant

final class DecisionTests: XCTestCase {
    func testParsesCleanJSON() throws {
        let decision = try Decision.parse(
            #"{"tool":"set_idle","message":"Good."}"#
        )
        XCTAssertEqual(
            decision,
            Decision(tool: .set_idle, snoozeMinutes: nil, message: "Good.")
        )
    }

    func testParsesFencedJSON() throws {
        let decision = try Decision.parse(
            """
            ```json
            {"tool":"set_angry","message":"Back to work."}
            ```
            """
        )
        XCTAssertEqual(decision.tool, .set_angry)
    }

    func testParsesFirstJSONObjectSurroundedByProse() throws {
        let decision = try Decision.parse(
            "Here is the call: {\"tool\":\"snooze\",\"snooze_minutes\":5,\"message\":\"Okay.\"} done"
        )
        XCTAssertEqual(decision.snoozeMinutes, 5)
    }

    func testMissingSnoozeMinutesDefaultsToTen() throws {
        let decision = try Decision.parse(
            #"{"tool":"snooze","message":"Ten minutes."}"#
        )
        XCTAssertEqual(decision.snoozeMinutes, 10)
    }

    func testSnoozeMinutesClampsToRange() throws {
        let high = try Decision.parse(
            #"{"tool":"snooze","snooze_minutes":500,"message":"Fine."}"#
        )
        let low = try Decision.parse(
            #"{"tool":"snooze","snooze_minutes":0,"message":"Fine."}"#
        )
        XCTAssertEqual(high.snoozeMinutes, 120)
        XCTAssertEqual(low.snoozeMinutes, 1)
    }

    func testParserHandlesBracesInsideMessage() throws {
        let decision = try Decision.parse(
            #"prefix {"tool":"set_idle","message":"Use {this} safely"} suffix"#
        )
        XCTAssertEqual(decision.message, "Use {this} safely")
    }
}
