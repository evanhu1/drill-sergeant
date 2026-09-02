import XCTest
@testable import DrillSergeant

@MainActor
final class OnboardingFlowTests: XCTestCase {
    func testWelcomeAsksForGoalAndSavesReply() async {
        let (settings, defaults, suiteName) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let chat = FakeChatPresenter()
        let scheduler = Scheduler(clock: TestClock())
        var permissionGranted = false
        let flow = makeFlow(chat: chat, scheduler: scheduler, settings: settings)
        flow.isPermissionGranted = { permissionGranted }
        flow.pollInterval = 0.001

        flow.start()

        XCTAssertEqual(settings.onboardingStep, .goal)
        XCTAssertEqual(chat.askedMessages.count, 1)
        XCTAssertTrue(chat.askedMessages[0].contains("Drill Sergeant reporting"))
        XCTAssertTrue(chat.askedMessages[0].contains("never leaves your Mac"))

        chat.onReply?("Finish the launch")

        XCTAssertEqual(settings.goal, "Finish the launch")
        XCTAssertEqual(settings.onboardingStep, .permission)
        XCTAssertTrue(chat.shownMessages.contains { $0.text.contains("Screen Recording") })

        permissionGranted = true
        await waitUntil { settings.onboardingStep == .relaunch }
    }

    func testPermissionStepSkipsWhenAlreadyGranted() async {
        let (settings, defaults, suiteName) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        settings.onboardingStep = .permission
        let chat = FakeChatPresenter()
        let scheduler = Scheduler(clock: TestClock())
        var checkReasons: [CheckReason] = []
        let flow = makeFlow(
            chat: chat,
            scheduler: scheduler,
            settings: settings,
            runCheck: { reason in
                checkReasons.append(reason)
                return Decision(tool: .set_idle, snoozeMinutes: nil, message: "")
            }
        )
        flow.isPermissionGranted = { true }
        flow.isOllamaReady = { true }
        flow.isYouTubeOpen = { true }
        flow.pollInterval = 0.001

        flow.start()

        XCTAssertEqual(settings.onboardingStep, .test)
        XCTAssertFalse(chat.shownMessages.contains { $0.text.contains("Screen Recording") })
        await waitUntil { checkReasons.count == 1 }
        flow.schedulerDidChange(to: .idle)
    }

    func testYouTubeDetectionRunsOnboardingCheck() async {
        let (settings, defaults, suiteName) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        settings.onboardingStep = .test
        let chat = FakeChatPresenter()
        let scheduler = Scheduler(clock: TestClock())
        var checkReasons: [CheckReason] = []
        let flow = makeFlow(
            chat: chat,
            scheduler: scheduler,
            settings: settings,
            runCheck: { reason in
                checkReasons.append(reason)
                return Decision(tool: .set_angry, snoozeMinutes: nil, message: "Close it!")
            }
        )
        flow.isOllamaReady = { true }
        flow.isYouTubeOpen = { true }
        flow.pollInterval = 0.001

        flow.start()

        await waitUntil { checkReasons.count == 1 }
        guard let reason = checkReasons.first else {
            return XCTFail("Expected an onboarding check")
        }
        guard case .onboarding = reason else {
            return XCTFail("Expected the onboarding check reason")
        }
        XCTAssertEqual(scheduler.state, .angry)

        scheduler.apply(Decision(tool: .set_idle, snoozeMinutes: nil, message: "Good."))
        flow.schedulerDidChange(to: scheduler.state)
        XCTAssertEqual(settings.onboardingStep, .done)
    }

    func testIdleAfterTestMarksOnboardingDone() async {
        let (settings, defaults, suiteName) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        settings.goal = "Write the README"
        settings.intervalMinutes = 12
        settings.onboardingStep = .test
        let chat = FakeChatPresenter()
        let scheduler = Scheduler(clock: TestClock())
        var didFinish = false
        var didRunCheck = false
        let flow = makeFlow(
            chat: chat,
            scheduler: scheduler,
            settings: settings,
            runCheck: { _ in
                didRunCheck = true
                return Decision(tool: .set_idle, snoozeMinutes: nil, message: "")
            }
        )
        flow.isOllamaReady = { true }
        flow.isYouTubeOpen = { true }
        flow.pollInterval = 0.001
        flow.onFinished = { didFinish = true }

        flow.start()
        await waitUntil { didRunCheck }
        flow.schedulerDidChange(to: .idle)

        XCTAssertEqual(settings.onboardingStep, .done)
        XCTAssertTrue(didFinish)
        XCTAssertEqual(chat.lastShown?.autoHide, true)
        XCTAssertEqual(
            chat.lastShown?.text,
            "That's how it works. Now back to: Write the README. Next check in 12 minutes."
        )
        XCTAssertNil(chat.onReply)
        XCTAssertNil(chat.onTap)
    }

    private func makeFlow(
        chat: FakeChatPresenter,
        scheduler: Scheduler,
        settings: Settings,
        runCheck: @escaping (CheckReason) async -> Decision? = { _ in nil }
    ) -> OnboardingFlow {
        OnboardingFlow(
            chat: chat,
            scheduler: scheduler,
            settings: settings,
            ollama: OllamaClient(model: settings.model),
            relaunch: {},
            runCheck: runCheck
        )
    }

    private func makeSettings() -> (Settings, UserDefaults, String) {
        let suiteName = "OnboardingFlowTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (Settings(defaults: defaults, environment: [:]), defaults, suiteName)
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(condition(), "Timed out waiting for condition")
    }
}

@MainActor
private final class FakeChatPresenter: ChatPresenter {
    struct ShownMessage {
        let text: String
        let autoHide: Bool
    }

    var onReply: ((String) -> Void)?
    var onTap: (() -> Void)?
    private(set) var shownMessages: [ShownMessage] = []
    private(set) var askedMessages: [String] = []
    private(set) var hideCount = 0

    var lastShown: ShownMessage? { shownMessages.last }

    func show(_ text: String, autoHide: Bool) {
        shownMessages.append(ShownMessage(text: text, autoHide: autoHide))
    }

    func ask(_ text: String) {
        askedMessages.append(text)
    }

    func hide() {
        hideCount += 1
    }
}
