import XCTest
@testable import DrillSergeant

@MainActor
final class CoordinatorSmokeTests: XCTestCase {
    func testCoordinatorCanBeConstructedWithoutCreatingWindows() {
        _ = AppCoordinator()
    }

    func testExternalQuitDuringPermissionRequestSchedulesOneReplacement() {
        let (settings, defaults, suiteName) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        settings.screenPermissionRequestPending = true
        var commands: [RelaunchCommand] = []
        let coordinator = AppCoordinator(
            settings: settings,
            launchReplacement: { commands.append($0) }
        )

        XCTAssertEqual(
            coordinator.applicationShouldTerminate(quitReason: nil),
            .terminateNow
        )
        XCTAssertEqual(
            coordinator.applicationShouldTerminate(quitReason: nil),
            .terminateNow
        )
        XCTAssertEqual(commands.count, 1)
    }

    func testExternalQuitIsCancelledWhenReplacementCannotBeScheduled() {
        let (settings, defaults, suiteName) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        settings.directCapturePermissionRequestPending = true
        let coordinator = AppCoordinator(
            settings: settings,
            launchReplacement: { _ in throw TestError.launchFailed }
        )

        XCTAssertEqual(
            coordinator.applicationShouldTerminate(quitReason: nil),
            .terminateCancel
        )
    }

    func testOrdinaryQuitWithoutPendingPermissionDoesNotRelaunch() {
        let (settings, defaults, suiteName) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var launchCount = 0
        let coordinator = AppCoordinator(
            settings: settings,
            launchReplacement: { _ in launchCount += 1 }
        )

        XCTAssertEqual(
            coordinator.applicationShouldTerminate(quitReason: nil),
            .terminateNow
        )
        XCTAssertEqual(launchCount, 0)
    }

    func testSessionEndingQuitNeverSchedulesReplacement() {
        let (settings, defaults, suiteName) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        settings.screenPermissionRequestPending = true
        var launchCount = 0
        let coordinator = AppCoordinator(
            settings: settings,
            launchReplacement: { _ in launchCount += 1 }
        )

        for reason in [kAEQuitAll, kAEShutDown, kAERestart, kAELogOut, kAEReallyLogOut] {
            XCTAssertEqual(
                coordinator.applicationShouldTerminate(quitReason: reason),
                .terminateNow
            )
        }
        XCTAssertEqual(launchCount, 0)
    }

    func testIntentionalQuitClearsPendingRequestsAndDoesNotRelaunch() {
        let (settings, defaults, suiteName) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        settings.screenPermissionRequestPending = true
        settings.directCapturePermissionRequestPending = true
        var launchCount = 0
        let coordinator = AppCoordinator(
            settings: settings,
            launchReplacement: { _ in launchCount += 1 }
        )

        coordinator.prepareForIntentionalQuit()

        XCTAssertFalse(settings.hasPendingPermissionRequest)
        XCTAssertEqual(
            coordinator.applicationShouldTerminate(quitReason: nil),
            .terminateNow
        )
        XCTAssertEqual(launchCount, 0)
    }

    // MARK: - Stale shout

    /// An angry bubble never times out, so a silent all-clear used to leave it shouting.
    func testSilentAllClearDismissesTheAngryBubble() {
        XCTAssertTrue(
            AppCoordinator.dismissesStaleShout(
                currentState: .angry,
                decision: Decision(tool: .set_idle, snoozeMinutes: nil, message: ""),
                isReplying: false
            )
        )
        XCTAssertTrue(
            AppCoordinator.dismissesStaleShout(
                currentState: .angry,
                decision: Decision(tool: .snooze, snoozeMinutes: 10, message: ""),
                isReplying: false
            )
        )
    }

    func testAStillAngryVerdictKeepsTheBubbleUp() {
        XCTAssertFalse(
            AppCoordinator.dismissesStaleShout(
                currentState: .angry,
                decision: Decision(tool: .set_angry, snoozeMinutes: nil, message: ""),
                isReplying: false
            )
        )
    }

    /// Hiding the bubble closes the reply field, so a half-typed answer is left alone.
    func testAReplyInProgressKeepsTheBubbleUp() {
        XCTAssertFalse(
            AppCoordinator.dismissesStaleShout(
                currentState: .angry,
                decision: Decision(tool: .set_idle, snoozeMinutes: nil, message: ""),
                isReplying: true
            )
        )
    }

    /// Only an angry bubble outstays its welcome; the rest already auto-hide.
    func testNothingIsDismissedWhenTheAppWasNotAngry() {
        for state in [CompanionState.idle, .watching, .happy] {
            XCTAssertFalse(
                AppCoordinator.dismissesStaleShout(
                    currentState: state,
                    decision: Decision(tool: .set_idle, snoozeMinutes: nil, message: ""),
                    isReplying: false
                ),
                "\(state.rawValue) should not trigger a dismissal"
            )
        }
    }

    private func makeSettings() -> (Settings, UserDefaults, String) {
        let suiteName = "CoordinatorSmokeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        return (Settings(defaults: defaults, environment: [:]), defaults, suiteName)
    }
}

private enum TestError: Error {
    case launchFailed
}
