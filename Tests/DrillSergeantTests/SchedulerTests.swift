import XCTest
@testable import DrillSergeant

@MainActor
final class SchedulerTests: XCTestCase {
    func testScheduledCheckUsesPreRollAndReschedulesAfterIdleDecision() {
        let clock = TestClock()
        let scheduler = Scheduler(clock: clock)
        let delegate = SchedulerDelegateSpy()
        scheduler.delegate = delegate

        scheduler.start()
        XCTAssertEqual(scheduler.nextCheckAt, Date(timeIntervalSince1970: 600))

        clock.advance(by: 539)
        XCTAssertEqual(scheduler.state, .idle)
        clock.advance(by: 1)
        XCTAssertEqual(scheduler.state, .watching)
        XCTAssertTrue(delegate.requests.isEmpty)

        clock.advance(by: 60)
        XCTAssertEqual(delegate.requests.count, 1)
        XCTAssertScheduled(delegate.requests[0])

        scheduler.apply(Decision(tool: .set_idle, snoozeMinutes: nil, message: ""))
        XCTAssertEqual(scheduler.state, .idle)
        XCTAssertEqual(scheduler.nextCheckAt, Date(timeIntervalSince1970: 1_200))
    }

    func testAngryPollThenIdleTransitionsThroughHappy() {
        let clock = TestClock()
        let scheduler = Scheduler(clock: clock)
        let delegate = SchedulerDelegateSpy()
        scheduler.delegate = delegate

        scheduler.checkNow()
        scheduler.apply(Decision(tool: .set_angry, snoozeMinutes: nil, message: "Move!"))
        XCTAssertEqual(scheduler.state, .angry)

        clock.advance(by: 30)
        XCTAssertEqual(delegate.requests.count, 2)
        XCTAssertAngryPoll(delegate.requests[1])

        scheduler.apply(Decision(tool: .set_idle, snoozeMinutes: nil, message: "Good."))
        XCTAssertEqual(scheduler.state, .happy)
        XCTAssertEqual(scheduler.nextCheckAt, Date(timeIntervalSince1970: 630))

        clock.advance(by: 30)
        XCTAssertEqual(scheduler.state, .idle)
    }

    func testSnoozeSchedulesRequestedDelay() {
        let clock = TestClock()
        let scheduler = Scheduler(clock: clock)
        scheduler.checkNow()

        scheduler.apply(Decision(tool: .snooze, snoozeMinutes: 15, message: "Fine."))

        XCTAssertEqual(scheduler.state, .idle)
        XCTAssertEqual(scheduler.nextCheckAt, Date(timeIntervalSince1970: 900))
    }

    func testInFlightGuardIgnoresDoubleManualTrigger() {
        let clock = TestClock()
        let scheduler = Scheduler(clock: clock)
        let delegate = SchedulerDelegateSpy()
        scheduler.delegate = delegate

        scheduler.checkNow()
        scheduler.checkNow()

        XCTAssertEqual(delegate.requests.count, 1)
        XCTAssertEqual(scheduler.state, .watching)
    }

    func testCheckNowFromIdleIsImmediateAndManual() {
        let scheduler = Scheduler(clock: TestClock())
        let delegate = SchedulerDelegateSpy()
        scheduler.delegate = delegate

        scheduler.checkNow()

        XCTAssertEqual(scheduler.state, .watching)
        XCTAssertEqual(delegate.requests.count, 1)
        XCTAssertManual(delegate.requests[0])
    }

    func testStopCancelsTimersAndReturnsToIdle() {
        let clock = TestClock()
        let scheduler = Scheduler(clock: clock)
        let delegate = SchedulerDelegateSpy()
        scheduler.delegate = delegate
        scheduler.start()

        scheduler.stop()
        clock.advance(by: 1_000)

        XCTAssertEqual(scheduler.state, .idle)
        XCTAssertNil(scheduler.nextCheckAt)
        XCTAssertTrue(delegate.requests.isEmpty)
    }

    private func XCTAssertScheduled(
        _ reason: CheckReason,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .scheduled = reason else {
            return XCTFail("Expected scheduled reason", file: file, line: line)
        }
    }

    private func XCTAssertAngryPoll(
        _ reason: CheckReason,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .angryPoll = reason else {
            return XCTFail("Expected angry poll reason", file: file, line: line)
        }
    }

    private func XCTAssertManual(
        _ reason: CheckReason,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .manual = reason else {
            return XCTFail("Expected manual reason", file: file, line: line)
        }
    }
}

@MainActor
private final class SchedulerDelegateSpy: SchedulerDelegate {
    var changes: [(CompanionState, CompanionState)] = []
    var requests: [CheckReason] = []

    func scheduler(
        _ scheduler: Scheduler,
        didChange state: CompanionState,
        from old: CompanionState
    ) {
        changes.append((old, state))
    }

    func schedulerRequestsCheck(_ scheduler: Scheduler, reason: CheckReason) {
        requests.append(reason)
    }
}
