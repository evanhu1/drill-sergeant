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
    private let preRollSeconds: TimeInterval
    private let angryPollSeconds: TimeInterval
    private let happySeconds: TimeInterval
    private var preRollToken: CancelToken?
    private var checkToken: CancelToken?
    private var stateToken: CancelToken?
    private var isStarted = false
    private var isCheckInFlight = false

    init(
        clock: Clock,
        intervalMinutes: Int = 10,
        preRollSeconds: TimeInterval = 30,
        angryPollSeconds: TimeInterval = 10,
        happySeconds: TimeInterval = 30
    ) {
        self.clock = clock
        self.intervalMinutes = max(1, intervalMinutes)
        self.preRollSeconds = max(0, preRollSeconds)
        self.angryPollSeconds = max(0, angryPollSeconds)
        self.happySeconds = max(0, happySeconds)
        stateChangedAt = clock.now
    }

    func start() {
        isStarted = true
        isCheckInFlight = false
        cancelAllTimers()
        transition(to: .idle)
        scheduleNextCheck(minutes: intervalMinutes)
    }

    func stop() {
        isStarted = false
        isCheckInFlight = false
        cancelAllTimers()
        nextCheckAt = nil
        transition(to: .idle)
    }

    func checkNow() {
        guard !isCheckInFlight else { return }
        isStarted = true
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
            apply(
                Decision(tool: .set_idle, snoozeMinutes: nil, message: "")
            )
        case .watching:
            enterWatching()
        case .angry:
            apply(
                Decision(tool: .set_angry, snoozeMinutes: nil, message: "")
            )
        case .happy:
            enterHappy(nextCheckMinutes: intervalMinutes)
        }
    }

    private func applyFromAngry(_ decision: Decision) {
        switch decision.tool {
        case .set_angry:
            scheduleAngryPoll()
        case .set_idle:
            enterHappy(nextCheckMinutes: intervalMinutes)
        case .snooze:
            enterHappy(nextCheckMinutes: decision.snoozeMinutes ?? 10)
        }
    }

    private func applyFromNonAngry(_ decision: Decision) {
        switch decision.tool {
        case .set_idle:
            transition(to: .idle)
            scheduleNextCheck(minutes: intervalMinutes)
        case .set_angry:
            cancelAllTimers()
            nextCheckAt = nil
            transition(to: .angry)
            scheduleAngryPoll()
        case .snooze:
            transition(to: .idle)
            scheduleNextCheck(minutes: decision.snoozeMinutes ?? 10)
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

        let delay = TimeInterval(max(1, minutes) * 60)
        nextCheckAt = clock.now.addingTimeInterval(delay)

        if delay > preRollSeconds, preRollSeconds > 0 {
            preRollToken = clock.after(delay - preRollSeconds) { [weak self] in
                guard let self, !self.isCheckInFlight else { return }
                self.transition(to: .watching)
            }
        } else {
            preRollToken = nil
        }

        checkToken = clock.after(delay) { [weak self] in
            guard let self, !self.isCheckInFlight else { return }
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
        stateToken = clock.after(angryPollSeconds) { [weak self] in
            guard let self, self.state == .angry else { return }
            self.requestCheck(reason: .angryPoll)
        }
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
