import XCTest
@testable import DrillSergeant

@MainActor
final class SettingsTests: XCTestCase {
    func testDefaultsAndPersistence() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = Settings(defaults: defaults, environment: [:])

        XCTAssertEqual(settings.model, "qwen3-vl:8b")
        XCTAssertEqual(settings.intervalMinutes, 10)
        XCTAssertEqual(settings.onboardingStep, .welcome)
        XCTAssertEqual(settings.ollamaBaseURL.absoluteString, "http://127.0.0.1:11434")

        settings.model = "custom:8b"
        settings.intervalMinutes = 15
        settings.onboardingStep = .test
        settings.ollamaBaseURL = URL(string: "http://localhost:9999")!

        let reloaded = Settings(defaults: defaults, environment: [:])
        XCTAssertEqual(reloaded.model, "custom:8b")
        XCTAssertEqual(reloaded.intervalMinutes, 15)
        XCTAssertEqual(reloaded.onboardingStep, .test)
        XCTAssertEqual(reloaded.ollamaBaseURL.absoluteString, "http://localhost:9999")
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

    func testInitializationRemovesRetiredSetting() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let retiredKey = String(
            decoding: [100, 115, 46, 103, 111, 97, 108],
            as: UTF8.self
        )
        defaults.set("Retired value", forKey: retiredKey)

        _ = Settings(defaults: defaults, environment: [:])

        XCTAssertNil(defaults.object(forKey: retiredKey))
    }

    func testResetEnvironmentClearsOnboarding() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(OnboardingStep.done.rawValue, forKey: "ds.onboardingStep")

        let settings = Settings(
            defaults: defaults,
            environment: ["DS_RESET_ONBOARDING": "1"]
        )

        XCTAssertEqual(settings.onboardingStep, .welcome)
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "DrillSergeantTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
