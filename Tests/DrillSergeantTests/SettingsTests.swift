import XCTest
@testable import DrillSergeant

@MainActor
final class SettingsTests: XCTestCase {
    func testDefaultsAndPersistence() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = Settings(defaults: defaults, environment: [:])

        XCTAssertEqual(settings.model, "qwen3-vl:8b-instruct")
        XCTAssertEqual(settings.intervalMinutes, 10)
        XCTAssertEqual(settings.onboardingStep, .permission)
        XCTAssertEqual(settings.ollamaBaseURL.absoluteString, "http://127.0.0.1:11434")
        XCTAssertFalse(settings.screenPermissionRequestPending)
        XCTAssertFalse(settings.directCapturePermissionRequestPending)
        XCTAssertFalse(settings.hasPendingPermissionRequest)
        XCTAssertEqual(settings.userPreferences, [])
        XCTAssertEqual(settings.workHours, .standard)
        XCTAssertTrue(settings.tracingEnabled)

        settings.model = "custom:8b"
        settings.intervalMinutes = 15
        settings.onboardingStep = .test
        settings.ollamaBaseURL = URL(string: "http://localhost:9999")!
        settings.screenPermissionRequestPending = true
        settings.directCapturePermissionRequestPending = true
        settings.workHours = try WorkHours(
            days: [.tuesday, .thursday],
            startTime: "10:30",
            endTime: "18:00"
        )
        XCTAssertTrue(settings.saveUserPreference("YouTube tutorials count as work."))
        XCTAssertFalse(settings.saveUserPreference("youtube tutorials count as work."))
        XCTAssertFalse(settings.saveUserPreference("   "))

        let reloaded = Settings(defaults: defaults, environment: [:])
        XCTAssertEqual(reloaded.model, "custom:8b")
        XCTAssertEqual(reloaded.intervalMinutes, 15)
        XCTAssertEqual(reloaded.onboardingStep, .test)
        XCTAssertEqual(reloaded.ollamaBaseURL.absoluteString, "http://localhost:9999")
        XCTAssertTrue(reloaded.screenPermissionRequestPending)
        XCTAssertTrue(reloaded.directCapturePermissionRequestPending)
        XCTAssertTrue(reloaded.hasPendingPermissionRequest)
        XCTAssertEqual(reloaded.userPreferences, ["YouTube tutorials count as work."])
        XCTAssertEqual(
            reloaded.workHours,
            try WorkHours(
                days: [.tuesday, .thursday],
                startTime: "10:30",
                endTime: "18:00"
            )
        )

        reloaded.clearPendingPermissionRequests()
        XCTAssertFalse(reloaded.hasPendingPermissionRequest)
    }

    func testEnvironmentOverridesDevelopmentValues() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = Settings(
            defaults: defaults,
            environment: [
                "DS_MODEL": "vision:test",
                "DS_INTERVAL_MINUTES": "3",
                "DS_OLLAMA_URL": "http://localhost:2222",
            ]
        )

        XCTAssertEqual(settings.model, "vision:test")
        XCTAssertEqual(settings.intervalMinutes, 3)
        XCTAssertEqual(settings.ollamaBaseURL.absoluteString, "http://localhost:2222")
    }

    func testResetEnvironmentClearsOnboarding() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(OnboardingStep.done.rawValue, forKey: "ds.onboardingStep")
        defaults.set(true, forKey: "ds.screenPermissionRequestPending")
        defaults.set(true, forKey: "ds.directCapturePermissionRequestPending")
        defaults.set(["Slack counts as work."], forKey: "ds.userPreferences")
        let customHours = try WorkHours(
            days: [.saturday, .sunday],
            startTime: "12:00",
            endTime: "20:00"
        )
        defaults.set(try JSONEncoder().encode(customHours), forKey: "ds.workHours")

        let settings = Settings(
            defaults: defaults,
            environment: ["DS_RESET_ONBOARDING": "1"]
        )

        XCTAssertEqual(settings.onboardingStep, .permission)
        XCTAssertFalse(settings.screenPermissionRequestPending)
        XCTAssertFalse(settings.directCapturePermissionRequestPending)
        XCTAssertEqual(settings.userPreferences, ["Slack counts as work."])
        XCTAssertEqual(settings.workHours, customHours)
    }

    func testTraceEnvironmentCanDisableTracing() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = Settings(defaults: defaults, environment: ["DS_TRACE": "0"])

        XCTAssertFalse(settings.tracingEnabled)
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "DrillSergeantTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
