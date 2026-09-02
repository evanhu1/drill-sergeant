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
