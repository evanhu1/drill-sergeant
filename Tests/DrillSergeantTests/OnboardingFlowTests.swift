import XCTest
@testable import DrillSergeant

@MainActor
final class OnboardingFlowTests: XCTestCase {
    func testWelcomeShowsPersistentMessageAndTapAdvances() async {
        let (settings, defaults, suiteName) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let chat = FakeChatPresenter()
        let scheduler = Scheduler(clock: TestClock())
        let flow = makeFlow(chat: chat, scheduler: scheduler, settings: settings)
        flow.isPermissionGranted = { false }
        flow.pollInterval = 0.001

        flow.start()

        XCTAssertEqual(settings.onboardingStep, .welcome)
        XCTAssertEqual(
            chat.lastShown?.text,
            "Drill Sergeant reporting. I watch your screen and shout at you when you slack "
                + "off. Everything runs on a local AI model, and your data never leaves your Mac."
        )
        XCTAssertEqual(chat.lastShown?.autoHide, false)
        XCTAssertEqual(chat.affordance, .onboardingNext)
        XCTAssertTrue(chat.askedMessages.isEmpty)
        XCTAssertNil(chat.onReply)
        XCTAssertNotNil(chat.onTap)
        XCTAssertTrue(defaults.persistentDomain(forName: suiteName)?.isEmpty ?? true)

        chat.onTap?()

        XCTAssertEqual(settings.onboardingStep, .permission)
        XCTAssertEqual(chat.affordance, .onboardingNext)
        XCTAssertTrue(chat.shownMessages.contains { $0.text.contains("Screen Recording") })
        XCTAssertFalse(chat.lastShown?.text.hasPrefix("Good.") ?? true)
        XCTAssertEqual(
            defaults.persistentDomain(forName: suiteName) as? [String: String],
            ["ds.onboardingStep": OnboardingStep.permission.rawValue]
        )

        let resumedChat = FakeChatPresenter()
        let resumedFlow = makeFlow(
            chat: resumedChat,
            scheduler: Scheduler(clock: TestClock()),
            settings: settings
        )
        resumedFlow.isPermissionGranted = { false }
        resumedFlow.start()

        XCTAssertTrue(resumedChat.shownMessages.contains { $0.text.contains("Screen Recording") })
        XCTAssertFalse(resumedChat.shownMessages.contains { $0.text.contains("Drill Sergeant reporting") })
    }

    /// The step used to disappear whenever `isPermissionGranted()` said yes, which is exactly what
    /// an inherited grant reports. It is always shown now, and nothing is asked for until a tap.
    func testPermissionStepIsShownEvenWhenPreflightSaysGranted() async {
        let (settings, defaults, suiteName) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        settings.onboardingStep = .permission
        let chat = FakeChatPresenter()
        var didRequest = false
        let flow = makeFlow(
            chat: chat,
            scheduler: Scheduler(clock: TestClock()),
            settings: settings
        )
        flow.isPermissionGranted = { true }
        flow.probePermission = { true }
        flow.requestPermission = { didRequest = true; return true }
        flow.pollInterval = 0.001

        flow.start()

        XCTAssertTrue(chat.shownMessages.contains { $0.text.contains("Screen Recording") })
        XCTAssertEqual(settings.onboardingStep, .permission)
        XCTAssertFalse(didRequest)
    }

    func testTapAdvancesToDirectCapturePermissionWhenScreenPermissionWorks() async {
        let (settings, defaults, suiteName) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        settings.onboardingStep = .permission
        let chat = FakeChatPresenter()
        let flow = makeFlow(
            chat: chat,
            scheduler: Scheduler(clock: TestClock()),
            settings: settings
        )
        flow.isPermissionGranted = { true }
        flow.probePermission = { true }
        flow.isOllamaReady = { false }
        flow.pollInterval = 0.001

        flow.start()
        chat.onTap?()

        await waitUntil { settings.onboardingStep == .directCapturePermission }
        XCTAssertFalse(chat.shownMessages.contains { $0.text.contains("restart") })
        XCTAssertEqual(chat.affordance, .onboardingNext)
        XCTAssertTrue(chat.lastShown?.text.contains("direct screen access") ?? false)
    }

    /// Recorded by macOS but not usable by this process yet: that is the case a relaunch fixes.
    func testGrantedButNotYetWorkingAsksForARelaunch() async {
        let (settings, defaults, suiteName) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        settings.onboardingStep = .permission
        let chat = FakeChatPresenter()
        let flow = makeFlow(
            chat: chat,
            scheduler: Scheduler(clock: TestClock()),
            settings: settings
        )
        var granted = false
        flow.isPermissionGranted = { granted }
        flow.probePermission = { false }
        flow.requestPermission = { granted = true; return true }
        flow.pollInterval = 0.001

        flow.start()
        chat.onTap?()

        await waitUntil { settings.onboardingStep == .relaunch }
        XCTAssertTrue(settings.screenPermissionRequestPending)
        XCTAssertEqual(chat.affordance, .onboardingNext)
        XCTAssertTrue(chat.shownMessages.contains { $0.text.contains("restart") })
    }

    func testPermissionRequestPersistsResumePointBeforeCallingSystemAPI() async {
        let (settings, defaults, suiteName) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        settings.onboardingStep = .permission
        let chat = FakeChatPresenter()
        let flow = makeFlow(
            chat: chat,
            scheduler: Scheduler(clock: TestClock()),
            settings: settings
        )
        flow.probePermission = { false }
        flow.requestPermission = {
            XCTAssertTrue(settings.screenPermissionRequestPending)
            return true
        }
        flow.isPermissionGranted = { true }
        flow.pollInterval = 0.001

        flow.start()
        chat.onTap?()

        await waitUntil { settings.onboardingStep == .relaunch }
    }

    func testUnresolvedPermissionRequestKeepsRelaunchMarker() async {
        let (settings, defaults, suiteName) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        settings.onboardingStep = .permission
        let chat = FakeChatPresenter()
        let flow = makeFlow(
            chat: chat,
            scheduler: Scheduler(clock: TestClock()),
            settings: settings
        )
        flow.probePermission = { false }
        flow.requestPermission = { false }
        flow.isPermissionGranted = { false }
        flow.pollInterval = 0.001

        flow.start()
        chat.onTap?()
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(settings.onboardingStep, .permission)
        XCTAssertTrue(settings.screenPermissionRequestPending)
        XCTAssertNotNil(chat.onTap)

        settings.onboardingStep = .welcome
        flow.start()
    }

    func testPendingPermissionRequestResumesAndAdvancesAfterSystemRelaunch() async {
        let (settings, defaults, suiteName) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        settings.onboardingStep = .permission
        settings.screenPermissionRequestPending = true
        let chat = FakeChatPresenter()
        let flow = makeFlow(
            chat: chat,
            scheduler: Scheduler(clock: TestClock()),
            settings: settings
        )
        flow.probePermission = { true }
        flow.isOllamaReady = { false }
        flow.pollInterval = 0.001

        flow.start()

        XCTAssertEqual(chat.lastShown?.text, "Checking Screen Recording permission…")
        await waitUntil { settings.onboardingStep == .directCapturePermission }
        XCTAssertFalse(settings.screenPermissionRequestPending)
    }

    func testPendingPermissionRequestWaitsForGrantToPropagateAfterRelaunch() async {
        let (settings, defaults, suiteName) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        settings.onboardingStep = .permission
        settings.screenPermissionRequestPending = true
        let chat = FakeChatPresenter()
        let flow = makeFlow(
            chat: chat,
            scheduler: Scheduler(clock: TestClock()),
            settings: settings
        )
        var probeCount = 0
        flow.probePermission = {
            probeCount += 1
            return probeCount == 3
        }
        flow.isPermissionGranted = { false }
        flow.isOllamaReady = { false }
        flow.pollInterval = 0.001

        flow.start()

        await waitUntil { settings.onboardingStep == .directCapturePermission }
        XCTAssertEqual(probeCount, 3)
        XCTAssertFalse(settings.screenPermissionRequestPending)
    }

    func testPendingPermissionRequestReturnsToPermissionStepAfterDenial() async {
        let (settings, defaults, suiteName) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        settings.onboardingStep = .permission
        settings.screenPermissionRequestPending = true
        let chat = FakeChatPresenter()
        let flow = makeFlow(
            chat: chat,
            scheduler: Scheduler(clock: TestClock()),
            settings: settings
        )
        flow.probePermission = { false }
        flow.isPermissionGranted = { false }
        flow.permissionResumeAttempts = 2
        flow.pollInterval = 0.001

        flow.start()

        await waitUntil { !settings.screenPermissionRequestPending }
        XCTAssertEqual(settings.onboardingStep, .permission)
        XCTAssertTrue(chat.shownMessages.contains { $0.text.contains("Click this bubble") })
    }

    func testRelaunchStepMovesOnOnceCaptureWorks() async {
        let (settings, defaults, suiteName) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        settings.onboardingStep = .relaunch
        let chat = FakeChatPresenter()
        let flow = makeFlow(
            chat: chat,
            scheduler: Scheduler(clock: TestClock()),
            settings: settings
        )
        flow.probePermission = { true }
        flow.isOllamaReady = { false }
        flow.pollInterval = 0.001

        flow.start()

        await waitUntil { settings.onboardingStep == .directCapturePermission }
    }

    func testDirectCapturePermissionExplainsAccessAndWaitsForTap() async {
        let (settings, defaults, suiteName) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        settings.onboardingStep = .directCapturePermission
        let chat = FakeChatPresenter()
        let flow = makeFlow(
            chat: chat,
            scheduler: Scheduler(clock: TestClock()),
            settings: settings
        )
        var requestCount = 0
        flow.requestDirectCapturePermission = {
            requestCount += 1
            return true
        }
        flow.isOllamaReady = { false }
        flow.pollInterval = 0.001

        flow.start()

        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(chat.affordance, .onboardingNext)
        XCTAssertTrue(chat.lastShown?.text.contains("automatically") ?? false)
        XCTAssertTrue(chat.lastShown?.text.contains("never audio") ?? false)
        XCTAssertNotNil(chat.onTap)

        chat.onTap?()

        XCTAssertEqual(chat.affordance, .onboardingNext)
        await waitUntil { settings.onboardingStep == .test }
        XCTAssertEqual(requestCount, 1)
        XCTAssertFalse(settings.directCapturePermissionRequestPending)
    }

    func testDirectCapturePermissionPersistsResumePointBeforeSystemRequest() async {
        let (settings, defaults, suiteName) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        settings.onboardingStep = .directCapturePermission
        let chat = FakeChatPresenter()
        let flow = makeFlow(
            chat: chat,
            scheduler: Scheduler(clock: TestClock()),
            settings: settings
        )
        flow.requestDirectCapturePermission = {
            XCTAssertEqual(settings.onboardingStep, .directCapturePermission)
            XCTAssertTrue(settings.directCapturePermissionRequestPending)
            return true
        }
        flow.isOllamaReady = { false }

        flow.start()
        chat.onTap?()

        await waitUntil { settings.onboardingStep == .test }
    }

    func testPendingDirectCapturePermissionResumesAfterRelaunch() async {
        let (settings, defaults, suiteName) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        settings.onboardingStep = .directCapturePermission
        settings.directCapturePermissionRequestPending = true
        let chat = FakeChatPresenter()
        let flow = makeFlow(
            chat: chat,
            scheduler: Scheduler(clock: TestClock()),
            settings: settings
        )
        var didRequest = false
        flow.requestDirectCapturePermission = {
            didRequest = true
            return true
        }
        flow.isOllamaReady = { false }

        flow.start()

        XCTAssertEqual(chat.lastShown?.text, "Checking direct screen access…")
        await waitUntil { settings.onboardingStep == .test }
        XCTAssertTrue(didRequest)
        XCTAssertFalse(settings.directCapturePermissionRequestPending)
    }

    func testDeniedPendingDirectCaptureRequestClearsStaleRelaunchMarker() async {
        let (settings, defaults, suiteName) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        settings.onboardingStep = .directCapturePermission
        settings.directCapturePermissionRequestPending = true
        let chat = FakeChatPresenter()
        let flow = makeFlow(
            chat: chat,
            scheduler: Scheduler(clock: TestClock()),
            settings: settings
        )
        flow.requestDirectCapturePermission = { false }

        flow.start()

        await waitUntil {
            chat.lastShown?.text.contains("still isn't available") == true
        }
        XCTAssertFalse(settings.directCapturePermissionRequestPending)
        XCTAssertNotNil(chat.onTap)
    }

    func testDeniedDirectCapturePermissionStaysOnRetryStep() async {
        let (settings, defaults, suiteName) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        settings.onboardingStep = .directCapturePermission
        let chat = FakeChatPresenter()
        let flow = makeFlow(
            chat: chat,
            scheduler: Scheduler(clock: TestClock()),
            settings: settings
        )
        flow.requestDirectCapturePermission = { false }

        flow.start()
        chat.onTap?()

        await waitUntil {
            chat.lastShown?.text.contains("still isn't available") == true
        }
        XCTAssertEqual(settings.onboardingStep, .directCapturePermission)
        XCTAssertTrue(settings.directCapturePermissionRequestPending)
        XCTAssertEqual(chat.affordance, .onboardingNext)
        XCTAssertNotNil(chat.onTap)
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
            "That's how it works. Back to work — next check in 12 minutes."
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
    var affordance: BubbleAffordance = .reply
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
