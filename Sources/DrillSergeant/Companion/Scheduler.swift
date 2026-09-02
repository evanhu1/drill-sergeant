import Foundation

@MainActor
protocol SchedulerDelegate: AnyObject {
    /// Called on every state change.
    func scheduler(
        _ scheduler: Scheduler,
        didChange state: CompanionState,
        from old: CompanionState
    )

    /// Requests a capture and model decision. The delegate completes it with `apply`.
    func schedulerRequestsCheck(_ scheduler: Scheduler, reason: CheckReason)
}

enum CheckReason {
    case scheduled
    case angryPoll
    case manual
    case onboarding
}

@MainActor
final class Scheduler {
    weak var delegate: SchedulerDelegate?

    private(set) var state: CompanionState = .idle
    private(set) var previousState: CompanionState = .idle
    private(set) var stateChangedAt: Date
    private(set) var nextCheckAt: Date?
    private(set) var workHours: WorkHours

    var isActiveNow: Bool {
        isWorkHoursOverrideActive || workHours.contains(clock.now, calendar: calendar)
    }

    var intervalMinutes: Int {
        didSet {
            if intervalMinutes < 1 {
                intervalMinutes = 1
                return
            }
            guard isStarted, state != .angry else { return }
            scheduleNextCheck(minutes: intervalMinutes)
        }
    }

    private let clock: Clock
    private let calendar: Calendar
    private let preRollSeconds: TimeInterval
    private let angryPollSeconds: TimeInterval
    private let happySeconds: TimeInterval
    private var preRollToken: CancelToken?
    private var checkToken: CancelToken?
    private var stateToken: CancelToken?
    private var isStarted = false
    private var isCheckInFlight = false
    private var isWorkHoursOverrideActive = false

    init(
        clock: Clock,
        intervalMinutes: Int = 10,
        workHours: WorkHours = .standard,
        calendar: Calendar = .current,
        preRollSeconds: TimeInterval = 30,
        angryPollSeconds: TimeInterval = 10,
        happySeconds: TimeInterval = 5
    ) {
        self.clock = clock
        self.intervalMinutes = max(1, intervalMinutes)
        self.workHours = workHours
        self.calendar = calendar
        self.preRollSeconds = max(0, preRollSeconds)
        self.angryPollSeconds = max(0, angryPollSeconds)
        self.happySeconds = max(0, happySeconds)
        stateChangedAt = clock.now
    }

    func start() {
        isStarted = true
        isCheckInFlight = false
        isWorkHoursOverrideActive = false
        cancelAllTimers()
        transition(to: .idle)
        scheduleNextCheck(minutes: intervalMinutes)
    }

    func stop() {
        isStarted = false
        isCheckInFlight = false
        isWorkHoursOverrideActive = false
        cancelAllTimers()
        nextCheckAt = nil
        transition(to: .idle)
    }

    func checkNow() {
        guard !isCheckInFlight else { return }
        isStarted = true
        isWorkHoursOverrideActive = true
        cancelAllTimers()
        nextCheckAt = nil
        transition(to: .watching)
        requestCheck(reason: .manual)
    }

    func apply(_ decision: Decision) {
        isCheckInFlight = false

        if state == .angry {
            applyFromAngry(decision)
        } else {
            applyFromNonAngry(decision)
        }
    }

    /// Forces the watching state without starting a check or timer.
    func enterWatching() {
        isStarted = true
        isCheckInFlight = false
        isWorkHoursOverrideActive = true
        cancelAllTimers()
        nextCheckAt = nil
        transition(to: .watching)
    }

    /// Forces a state while preserving that state's normal timers for developer tools.
    func debugTransition(to state: CompanionState) {
        isStarted = true
        isCheckInFlight = false
        cancelAllTimers()
        nextCheckAt = nil

        switch state {
        case .idle:
            isWorkHoursOverrideActive = false
            apply(
                Decision(tool: .set_idle, snoozeMinutes: nil, message: "")
            )
        case .watching:
            enterWatching()
        case .angry:
            isWorkHoursOverrideActive = true
            apply(
                Decision(tool: .set_angry, snoozeMinutes: nil, message: "")
            )
        case .happy:
            isWorkHoursOverrideActive = false
            enterHappy(nextCheckMinutes: intervalMinutes)
        }
    }

    private func applyFromAngry(_ decision: Decision) {
        switch decision.tool {
        case .set_angry:
            scheduleAngryPoll()
        case .set_idle:
            isWorkHoursOverrideActive = false
            enterHappy(nextCheckMinutes: intervalMinutes)
        case .snooze:
            isWorkHoursOverrideActive = false
            enterHappy(nextCheckMinutes: decision.snoozeMinutes ?? 10)
        case .save_user_preference:
            scheduleAngryPoll()
        case .set_work_hours:
            isWorkHoursOverrideActive = false
            if let workHours = decision.workHours {
                self.workHours = workHours
            }
            if workHours.contains(clock.now, calendar: calendar) {
                scheduleAngryPoll()
            } else {
                suspendUntilWorkHours()
            }
        }
    }

    private func applyFromNonAngry(_ decision: Decision) {
        switch decision.tool {
        case .set_idle:
            isWorkHoursOverrideActive = false
            transition(to: .idle)
            scheduleNextCheck(minutes: intervalMinutes)
        case .set_angry:
            cancelAllTimers()
            nextCheckAt = nil
            transition(to: .angry)
            scheduleAngryPoll()
        case .snooze:
            isWorkHoursOverrideActive = false
            transition(to: .idle)
            scheduleNextCheck(minutes: decision.snoozeMinutes ?? 10)
        case .save_user_preference:
            isWorkHoursOverrideActive = false
            transition(to: .idle)
            scheduleNextCheck(minutes: intervalMinutes)
        case .set_work_hours:
            isWorkHoursOverrideActive = false
            if let workHours = decision.workHours {
                self.workHours = workHours
            }
            transition(to: .idle)
            scheduleNextCheck(minutes: intervalMinutes)
        }
    }

    private func enterHappy(nextCheckMinutes: Int) {
        cancelAllTimers()
        transition(to: .happy)
        scheduleNextCheck(minutes: nextCheckMinutes)
        stateToken = clock.after(happySeconds) { [weak self] in
            guard let self, self.state == .happy else { return }
            self.transition(to: .idle)
        }
    }

    private func scheduleNextCheck(minutes: Int) {
        preRollToken?.cancel()
        checkToken?.cancel()

        let requestedDelay = TimeInterval(max(1, minutes) * 60)
        let requestedDate = clock.now.addingTimeInterval(requestedDelay)
        let checkDate: Date
        let startsNewWorkWindow: Bool
        if workHours.contains(requestedDate, calendar: calendar) {
            checkDate = requestedDate
            startsNewWorkWindow = false
        } else if let nextStart = workHours.nextStart(
            onOrAfter: requestedDate,
            calendar: calendar
        ) {
            checkDate = nextStart
            startsNewWorkWindow = true
        } else {
            nextCheckAt = nil
            Log.error("Could not find the next work-hours window")
            return
        }

        let delay = max(0, checkDate.timeIntervalSince(clock.now))
        nextCheckAt = checkDate

        let preRollDate = checkDate.addingTimeInterval(-preRollSeconds)
        if !startsNewWorkWindow,
           delay > preRollSeconds,
           preRollSeconds > 0,
           workHours.contains(preRollDate, calendar: calendar) {
            preRollToken = clock.after(delay - preRollSeconds) { [weak self] in
                guard let self, !self.isCheckInFlight else { return }
                self.transition(to: .watching)
            }
        } else {
            preRollToken = nil
        }

        checkToken = clock.after(delay) { [weak self] in
            guard let self, !self.isCheckInFlight else { return }
            guard self.workHours.contains(self.clock.now, calendar: self.calendar) else {
                self.scheduleNextCheck(minutes: self.intervalMinutes)
                return
            }
            self.preRollToken?.cancel()
            self.preRollToken = nil
            self.checkToken = nil
            self.nextCheckAt = nil
            self.transition(to: .watching)
            self.requestCheck(reason: .scheduled)
        }
    }

    private func scheduleAngryPoll() {
        stateToken?.cancel()
        guard isActiveNow else {
            suspendUntilWorkHours()
            return
        }

        var delay = angryPollSeconds
        var endsWorkWindow = false
        if !isWorkHoursOverrideActive,
           let end = workHours.intervalEnd(containing: clock.now, calendar: calendar) {
            let untilEnd = max(0, end.timeIntervalSince(clock.now))
            if untilEnd <= delay {
                delay = untilEnd
                endsWorkWindow = true
            }
        }

        stateToken = clock.after(delay) { [weak self] in
            guard let self, self.state == .angry else { return }
            if endsWorkWindow {
                self.suspendUntilWorkHours()
                return
            }
            self.requestCheck(reason: .angryPoll)
        }
    }

    private func suspendUntilWorkHours() {
        isWorkHoursOverrideActive = false
        cancelAllTimers()
        transition(to: .idle)
        scheduleNextCheck(minutes: intervalMinutes)
    }

    private func requestCheck(reason: CheckReason) {
        guard !isCheckInFlight else { return }
        isCheckInFlight = true
        delegate?.schedulerRequestsCheck(self, reason: reason)
    }

    private func transition(to newState: CompanionState) {
        guard state != newState else { return }
        let old = state
        previousState = old
        state = newState
        stateChangedAt = clock.now
        delegate?.scheduler(self, didChange: newState, from: old)
    }

    private func cancelAllTimers() {
        preRollToken?.cancel()
        checkToken?.cancel()
        stateToken?.cancel()
        preRollToken = nil
        checkToken = nil
        stateToken = nil
    }
}
