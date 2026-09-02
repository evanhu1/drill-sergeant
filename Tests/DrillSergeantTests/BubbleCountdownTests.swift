import XCTest
@testable import DrillSergeant

final class BubbleCountdownTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    func testFullAtTheStart() {
        let countdown = BubbleCountdown(start: start, duration: 10)
        XCTAssertEqual(countdown.remaining(at: start), 1, accuracy: 0.0001)
    }

    func testDrainsLinearly() {
        let countdown = BubbleCountdown(start: start, duration: 10)
        XCTAssertEqual(
            countdown.remaining(at: start.addingTimeInterval(2.5)),
            0.75,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            countdown.remaining(at: start.addingTimeInterval(7)),
            0.3,
            accuracy: 0.0001
        )
    }

    func testClampsPastTheDeadlineAndBeforeTheStart() {
        let countdown = BubbleCountdown(start: start, duration: 10)
        XCTAssertEqual(countdown.remaining(at: start.addingTimeInterval(10)), 0)
        XCTAssertEqual(countdown.remaining(at: start.addingTimeInterval(45)), 0)
        XCTAssertEqual(countdown.remaining(at: start.addingTimeInterval(-5)), 1)
    }

    func testZeroDurationIsEmptyRatherThanInfinite() {
        let countdown = BubbleCountdown(start: start, duration: 0)
        XCTAssertEqual(countdown.remaining(at: start), 0)
    }
}
