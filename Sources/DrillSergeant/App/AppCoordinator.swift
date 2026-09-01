// STUB: implemented in wave 2
import AppKit

@MainActor
final class AppCoordinator: SchedulerDelegate {
    init() {}

    func start() {}

    func relaunch() {}

    func checkNow() {}

    func promptForGoal() {}

    func quit() {}

    func scheduler(
        _ scheduler: Scheduler,
        didChange state: CompanionState,
        from old: CompanionState
    ) {}

    func schedulerRequestsCheck(_ scheduler: Scheduler, reason: CheckReason) {}
}
