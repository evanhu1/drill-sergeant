import XCTest
@testable import DrillSergeant

@MainActor
final class SchedulerTests: XCTestCase {
    func testScheduledCheckUsesPreRollAndReschedulesAfterIdleDecision() {
        let clock = TestClock()
        let scheduler = Scheduler(clock: clock, workHours: .always)
        let delegate = SchedulerDelegateSpy()
        scheduler.delegate = delegate

        scheduler.start()
        XCTAssertEqual(scheduler.nextCheckAt, Date(timeIntervalSince1970: 600))

        clock.advance(by: 569)
        XCTAssertEqual(scheduler.state, .idle)
        clock.advance(by: 1)
        XCTAssertEqual(scheduler.state, .watching)
        XCTAssertTrue(delegate.requests.isEmpty)

        clock.advance(by: 30)
        XCTAssertEqual(delegate.requests.count, 1)
        XCTAssertScheduled(delegate.requests[0])

        scheduler.apply(Decision(tool: .set_idle, snoozeMinutes: nil, message: ""))
        XCTAssertEqual(scheduler.state, .idle)
        XCTAssertEqual(scheduler.nextCheckAt, Date(timeIntervalSince1970: 1_200))
    }

    func testAngryPollThenIdleTransitionsThroughHappy() {
        let clock = TestClock()
        let scheduler = Scheduler(clock: clock, workHours: .always)
        let delegate = SchedulerDelegateSpy()
        scheduler.delegate = delegate

        scheduler.checkNow()
        scheduler.apply(Decision(tool: .set_angry, snoozeMinutes: nil, message: "Move!"))
        XCTAssertEqual(scheduler.state, .angry)

        clock.advance(by: 10)
        XCTAssertEqual(delegate.requests.count, 2)
        XCTAssertAngryPoll(delegate.requests[1])

        scheduler.apply(Decision(tool: .set_idle, snoozeMinutes: nil, message: "Good."))
        XCTAssertEqual(scheduler.state, .happy)
        XCTAssertEqual(scheduler.nextCheckAt, Date(timeIntervalSince1970: 610))

        clock.advance(by: 5)
        XCTAssertEqual(scheduler.state, .idle)
    }

    func testSnoozeSchedulesRequestedDelay() {
        let clock = TestClock()
        let scheduler = Scheduler(clock: clock, workHours: .always)
        scheduler.checkNow()

        scheduler.apply(Decision(tool: .snooze, snoozeMinutes: 15, message: "Fine."))

        XCTAssertEqual(scheduler.state, .idle)
        XCTAssertEqual(scheduler.nextCheckAt, Date(timeIntervalSince1970: 900))
    }

    func testSavingPreferenceResumesMonitoringWithoutChangingVerdict() {
        let clock = TestClock()
        let scheduler = Scheduler(clock: clock, workHours: .always)
        let delegate = SchedulerDelegateSpy()
        scheduler.delegate = delegate
        let decision = Decision(
            tool: .save_user_preference,
            snoozeMinutes: nil,
            message: "Got it.",
            text: "YouTube tutorials count as work."
        )

        scheduler.checkNow()
        scheduler.apply(decision)
        XCTAssertEqual(scheduler.state, .idle)
        XCTAssertEqual(scheduler.nextCheckAt, Date(timeIntervalSince1970: 600))

        scheduler.debugTransition(to: .angry)
        scheduler.apply(decision)
        XCTAssertEqual(scheduler.state, .angry)
        clock.advance(by: 10)
        XCTAssertEqual(scheduler.state, .angry)
        XCTAssertEqual(delegate.requests.count, 2)
        XCTAssertAngryPoll(delegate.requests[1])
    }

    func testInFlightGuardIgnoresDoubleManualTrigger() {
        let clock = TestClock()
        let scheduler = Scheduler(clock: clock, workHours: .always)
        let delegate = SchedulerDelegateSpy()
        scheduler.delegate = delegate

        scheduler.checkNow()
        scheduler.checkNow()

        XCTAssertEqual(delegate.requests.count, 1)
        XCTAssertEqual(scheduler.state, .watching)
    }

    func testCheckNowFromIdleIsImmediateAndManual() {
        let scheduler = Scheduler(clock: TestClock(), workHours: .always)
        let delegate = SchedulerDelegateSpy()
        scheduler.delegate = delegate

        scheduler.checkNow()

        XCTAssertEqual(scheduler.state, .watching)
        XCTAssertEqual(delegate.requests.count, 1)
        XCTAssertManual(delegate.requests[0])
    }

    func testStopCancelsTimersAndReturnsToIdle() {
        let clock = TestClock()
        let scheduler = Scheduler(clock: clock, workHours: .always)
        let delegate = SchedulerDelegateSpy()
        scheduler.delegate = delegate
        scheduler.start()

        scheduler.stop()
        clock.advance(by: 1_000)

        XCTAssertEqual(scheduler.state, .idle)
        XCTAssertNil(scheduler.nextCheckAt)
        XCTAssertTrue(delegate.requests.isEmpty)
    }

    func testDebugTransitionsUseNormalStateTimers() {
        let clock = TestClock()
        let scheduler = Scheduler(clock: clock, workHours: .always)
        let delegate = SchedulerDelegateSpy()
        scheduler.delegate = delegate

        scheduler.debugTransition(to: .angry)
        XCTAssertEqual(scheduler.state, .angry)
        clock.advance(by: 10)
        XCTAssertEqual(delegate.requests.count, 1)
        XCTAssertAngryPoll(delegate.requests[0])

        scheduler.debugTransition(to: .idle)
        XCTAssertEqual(scheduler.state, .happy)
        XCTAssertEqual(scheduler.nextCheckAt, Date(timeIntervalSince1970: 610))
        clock.advance(by: 5)
        XCTAssertEqual(scheduler.state, .idle)

        scheduler.debugTransition(to: .watching)
        XCTAssertEqual(scheduler.state, .watching)
        XCTAssertNil(scheduler.nextCheckAt)

        scheduler.debugTransition(to: .idle)
        XCTAssertEqual(scheduler.state, .idle)
        XCTAssertEqual(scheduler.nextCheckAt, Date(timeIntervalSince1970: 615))

        scheduler.debugTransition(to: .angry)
        scheduler.debugTransition(to: .happy)
        XCTAssertEqual(scheduler.state, .happy)
        XCTAssertEqual(scheduler.nextCheckAt, Date(timeIntervalSince1970: 615))
    }

    func testAutomaticCheckWaitsForMondayOpeningWithoutEarlyPreRoll() throws {
        let clock = TestClock(now: try date("2026-09-04 16:55:00"))
        let scheduler = Scheduler(
            clock: clock,
            intervalMinutes: 10,
            workHours: .standard,
            calendar: calendar
        )
        let delegate = SchedulerDelegateSpy()
        scheduler.delegate = delegate

        scheduler.start()

        let opening = try date("2026-09-07 09:00:00")
        XCTAssertEqual(scheduler.nextCheckAt, opening)
        clock.advance(by: opening.timeIntervalSince(clock.now) - 1)
        XCTAssertEqual(scheduler.state, .idle)
        XCTAssertTrue(delegate.requests.isEmpty)

        clock.advance(by: 1)
        XCTAssertEqual(scheduler.state, .watching)
        XCTAssertEqual(delegate.requests.count, 1)
        XCTAssertScheduled(delegate.requests[0])
    }

    func testAutomaticAngryPollStopsAtClosingTime() throws {
        let clock = TestClock(now: try date("2026-09-04 16:58:50"))
        let scheduler = Scheduler(
            clock: clock,
            intervalMinutes: 1,
            workHours: .standard,
            calendar: calendar
        )
        let delegate = SchedulerDelegateSpy()
        scheduler.delegate = delegate

        scheduler.start()
        clock.advance(by: 60)
        XCTAssertEqual(delegate.requests.count, 1)
        scheduler.apply(Decision(tool: .set_angry, snoozeMinutes: nil, message: "Move!"))

        clock.advance(by: 10)

        XCTAssertEqual(scheduler.state, .idle)
        XCTAssertEqual(delegate.requests.count, 1)
        XCTAssertEqual(scheduler.nextCheckAt, try date("2026-09-07 09:00:00"))
    }

    func testManualCheckAndAngryFollowUpBypassWorkHours() throws {
        let clock = TestClock(now: try date("2026-09-05 12:00:00"))
        let scheduler = Scheduler(
            clock: clock,
            workHours: .standard,
            calendar: calendar
        )
        let delegate = SchedulerDelegateSpy()
        scheduler.delegate = delegate

        scheduler.checkNow()
        scheduler.apply(Decision(tool: .set_angry, snoozeMinutes: nil, message: "Move!"))
        clock.advance(by: 10)

        XCTAssertEqual(scheduler.state, .angry)
        XCTAssertEqual(delegate.requests.count, 2)
        XCTAssertAngryPoll(delegate.requests[1])
    }

    func testSetWorkHoursReplacesScheduleImmediately() throws {
        let clock = TestClock(now: try date("2026-09-07 10:00:00"))
        let scheduler = Scheduler(
            clock: clock,
            workHours: .standard,
            calendar: calendar
        )
        let hours = try WorkHours(
            days: [.tuesday, .thursday],
            startTime: "10:00",
            endTime: "18:00"
        )

        scheduler.checkNow()
        scheduler.apply(
            Decision(
                tool: .set_work_hours,
                snoozeMinutes: nil,
                message: "Updated.",
                workHours: hours
            )
        )

        XCTAssertEqual(scheduler.workHours, hours)
        XCTAssertEqual(scheduler.state, .idle)
        XCTAssertEqual(scheduler.nextCheckAt, try date("2026-09-08 10:00:00"))
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }

    private func date(_ value: String) throws -> Date {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return try XCTUnwrap(formatter.date(from: value))
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
