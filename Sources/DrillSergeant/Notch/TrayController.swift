import Foundation

/// Decides whether the notch tray is extended from state, pin, and hover inputs.
@MainActor
final class TrayController {
    private let clock: Clock
    private let idleDelay: TimeInterval
    private var idleToken: CancelToken?

    var onExtensionChange: ((Bool) -> Void)?

    private(set) var state: CompanionState
    private(set) var pinned = false
    private(set) var hovering = false
    private(set) var isExtended = true

    init(
        clock: Clock,
        state: CompanionState = .idle,
        idleDelay: TimeInterval = 5
    ) {
        self.clock = clock
        self.state = state
        self.idleDelay = idleDelay
        updateForCurrentInputs(restartIdleTimer: true)
    }

    func setState(_ state: CompanionState) {
        guard self.state != state else { return }
        self.state = state
        updateForCurrentInputs(restartIdleTimer: true)
    }

    func setPinned(_ pinned: Bool) {
        guard self.pinned != pinned else { return }
        self.pinned = pinned
        updateForCurrentInputs(restartIdleTimer: true)
    }

    func setHovering(_ hovering: Bool) {
        guard self.hovering != hovering else { return }
        self.hovering = hovering
        updateForCurrentInputs(restartIdleTimer: true)
    }

    /// Directly sets the presentation until the next input change.
    func setExtended(_ extended: Bool) {
        cancelIdleTimer()
        publish(extended)
    }

    private func updateForCurrentInputs(restartIdleTimer: Bool) {
        guard state == .idle else {
            cancelIdleTimer()
            publish(true)
            return
        }

        guard !pinned, !hovering else {
            cancelIdleTimer()
            publish(true)
            return
        }

        if restartIdleTimer {
            scheduleIdleTimer()
        }
    }

    private func scheduleIdleTimer() {
        cancelIdleTimer()
        idleToken = clock.after(idleDelay) { [weak self] in
            guard let self else { return }
            self.idleToken = nil
            guard self.state == .idle, !self.pinned, !self.hovering else { return }
            self.publish(false)
        }
    }

    private func cancelIdleTimer() {
        idleToken?.cancel()
        idleToken = nil
    }

    private func publish(_ extended: Bool) {
        guard isExtended != extended else { return }
        isExtended = extended
        onExtensionChange?(extended)
    }
}
