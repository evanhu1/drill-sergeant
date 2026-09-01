import XCTest
@testable import DrillSergeant

@MainActor
final class ClockTests: XCTestCase {
    func testAdvanceRunsEntriesInChronologicalOrder() {
        let clock = TestClock()
        var values: [Int] = []
        _ = clock.after(20) { values.append(2) }
        _ = clock.after(10) { values.append(1) }

        clock.advance(by: 20)

        XCTAssertEqual(values, [1, 2])
        XCTAssertEqual(clock.now, Date(timeIntervalSince1970: 20))
    }

    func testCancelPreventsScheduledBlock() {
        let clock = TestClock()
        var wasCalled = false
        let token = clock.after(1) { wasCalled = true }
        token.cancel()

        clock.advance(by: 1)

        XCTAssertFalse(wasCalled)
        XCTAssertTrue(token.isCancelled)
    }

    func testScheduledBlockCanScheduleAnotherDueBlock() {
        let clock = TestClock()
        var values: [Int] = []
        _ = clock.after(5) {
            values.append(1)
            _ = clock.after(2) { values.append(2) }
        }

        clock.advance(by: 10)

        XCTAssertEqual(values, [1, 2])
    }
}
