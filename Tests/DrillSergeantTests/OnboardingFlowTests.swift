import XCTest
@testable import DrillSergeant

@MainActor
final class OnboardingFlowTests: XCTestCase {
    // MARK: - One bubble, one click

    func testFirstBubbleAsksForPermissionAndIsTheOnlyClick() async {
        let (settings, defaults, suiteName) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let chat = FakeChatPresenter()
        let flow = makeFlow(chat: chat, settings: settings)
        flow.isPermissionGranted = { false }
        flow.pollInterval = 0.001

        flow.start()

        XCTAssertEqual(chat.lastShown?.text, OnboardingFlow.introText)
        XCTAssertTrue(chat.lastShown?.text.contains("Click here") ?? false)
        XCTAssertEqual(chat.lastShown?.autoHide, false)
        XCTAssertEqual(chat.affordance, .click)
        XCTAssertEqual(settings.onboardingStep, .permission)
        XCTAssertNotNil(chat.onTap)
        XCTAssertNotNil(chat.onClose)
        XCTAssertNil(chat.onReply)
    }

    /// Nothing may be requested before the user presses the bubble.
    func testPermissionStepIsShownEvenWhenPreflightSaysGranted() async {
        let (settings, defaults, suiteName) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        settings.onboardingStep = .permission
        let chat = FakeChatPresenter()
        var didRequest = false
        let flow = makeFlow(chat: chat, settings: settings)
        flow.isPermissionGranted = { true }
        flow.probePermission = { true }
        flow.requestPermission = { didRequest = true; return true }
        flow.pollInterval = 0.001

        flow.start()

        XCTAssertEqual(chat.lastShown?.text, OnboardingFlow.introText)
        XCTAssertEqual(settings.onboardingStep, .permission)
        XCTAssertFalse(didRequest)
    }

    func testCloseDuringOnboardingQuits() {
        let (settings, defaults, suiteName) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let chat = FakeChatPresenter()
        var quitCount = 0
        let flow = makeFlow(chat: chat, settings: settings, quit: { quitCount += 1 })

        flow.start()
        chat.onClose?()

        XCTAssertEqual(quitCount, 1)
    }

    // MARK: - Direct capture follows on its own

    /// The second macOS prompt belongs to the same request, so no bubble sits between them.
    func testGrantChainsStraightIntoDirectCaptureWithoutAnotherTap() async {
        let (settings, defaults, suiteName) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        settings.onboardingStep = .permission
        let chat = FakeChatPresenter()
        var directRequestCount = 0
        let flow = makeFlow(chat: chat, settings: settings)
        flow.isPermissionGranted = { true }
        flow.probePermission = { true }
        flow.requestDirectCapturePermission = { directRequestCount += 1; return true }
        flow.modelState = { .waitingForOllama }
        flow.pollInterval = 0.001

        flow.start()
        chat.onTap?()

        await waitUntil { settings.onboardingStep == .test }
        XCTAssertEqual(directRequestCount, 1)
        XCTAssertEqual(chat.tapHandlerAssignments.filter { $0 }.count, 1)
        XCTAssertFalse(chat.shownMessages.contains { $0.text.contains("Click this bubble") })
        XCTAssertFalse(settings.directCapturePermissionRequestPending)
    }

    func testDirectCaptureRequestIsMarkedPendingBeforeItRuns() async {
        let (settings, defaults, suiteName) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        settings.onboardingStep = .directCapturePermission
        let chat = FakeChatPresenter()
        let flow = makeFlow(chat: chat, settings: settings)
        flow.requestDirectCapturePermission = {
            XCTAssertTrue(settings.directCapturePermissionRequestPending)
            return true
        }
        flow.modelState = { .waitingForOllama }

        flow.start()

        XCTAssertEqual(chat.lastShown?.text, "Checking direct screen access…")
        await waitUntil { settings.onboardingStep == .test }
    }

    func testDeniedDirectCapturePermissionOffersARetry() async {
        let (settings, defaults, suiteName) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        settings.onboardingStep = .directCapturePermission
        let chat = FakeChatPresenter()
        let flow = makeFlow(chat: chat, settings: settings)
        flow.requestDirectCapturePermission = { false }

        flow.start()

        await waitUntil { chat.lastShown?.text.contains("still isn't available") == true }
        XCTAssertEqual(settings.onboardingStep, .directCapturePermission)
        XCTAssertFalse(settings.directCapturePermissionRequestPending)
        XCTAssertEqual(chat.affordance, .click)
        XCTAssertNotNil(chat.onTap)
    }

    // MARK: - Restart

    /// The restart is bookkeeping, so the app does it rather than asking.
    func testGrantedButNotYetWorkingRestartsItself() async {
        let (settings, defaults, suiteName) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        settings.onboardingStep = .permission
        let chat = FakeChatPresenter()
        var relaunchCount = 0
        let flow = makeFlow(chat: chat, settings: settings, relaunch: { relaunchCount += 1 })
        var granted = false
        flow.isPermissionGranted = { granted }
        flow.probePermission = { false }
        flow.requestPermission = { granted = true; return true }
        flow.pollInterval = 0.001

        flow.start()
        chat.onTap?()

        await waitUntil { relaunchCount == 1 }
        XCTAssertEqual(settings.onboardingStep, .relaunch)
        XCTAssertTrue(settings.screenPermissionRequestPending)
        XCTAssertTrue(settings.didAutoRelaunchForPermission)
        XCTAssertEqual(chat.lastShown?.text, "Permission granted. Restarting myself…")
        XCTAssertNil(chat.onTap)
    }

    /// A second automatic restart would only loop, so it becomes a button.
    func testSecondRestartIsOfferedRatherThanTaken() async {
        let (settings, defaults, suiteName) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        settings.onboardingStep = .permission
        settings.didAutoRelaunchForPermission = true
        let chat = FakeChatPresenter()
        var relaunchCount = 0
        let flow = makeFlow(chat: chat, settings: settings, relaunch: { relaunchCount += 1 })
        flow.isPermissionGranted = { true }
        flow.probePermission = { false }
        flow.requestPermission = { true }
        flow.pollInterval = 0.001

        flow.start()
        chat.onTap?()

        await waitUntil { settings.onboardingStep == .relaunch }
        XCTAssertEqual(relaunchCount, 0)
        XCTAssertEqual(chat.affordance, .click)
        XCTAssertTrue(chat.shownMessages.contains { $0.text.contains("Click here to restart") })

        chat.onTap?()
        XCTAssertEqual(relaunchCount, 1)
    }

    func testPendingPermissionRequestResumesAndAdvancesAfterSystemRelaunch() async {
        let (settings, defaults, suiteName) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        settings.onboardingStep = .permission
        settings.screenPermissionRequestPending = true
        let chat = FakeChatPresenter()
        let flow = makeFlow(chat: chat, settings: settings)
        flow.probePermission = { true }
        flow.modelState = { .waitingForOllama }
        flow.pollInterval = 0.001

        flow.start()

        XCTAssertEqual(chat.lastShown?.text, "Checking Screen Recording permission…")
        await waitUntil { settings.onboardingStep == .test }
        XCTAssertFalse(settings.screenPermissionRequestPending)
    }

    func testPendingPermissionRequestWaitsForGrantToPropagateAfterRelaunch() async {
        let (settings, defaults, suiteName) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        settings.onboardingStep = .relaunch
        settings.screenPermissionRequestPending = true
        let chat = FakeChatPresenter()
        let flow = makeFlow(chat: chat, settings: settings)
        var probeCount = 0
        flow.probePermission = {
            probeCount += 1
            return probeCount == 3
        }
        flow.isPermissionGranted = { false }
        flow.modelState = { .waitingForOllama }
        flow.pollInterval = 0.001

        flow.start()

        await waitUntil { settings.onboardingStep == .test }
        XCTAssertEqual(probeCount, 3)
    }

    func testPendingPermissionRequestReturnsToTheAskAfterDenial() async {
        let (settings, defaults, suiteName) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        settings.onboardingStep = .permission
        settings.screenPermissionRequestPending = true
        let chat = FakeChatPresenter()
        let flow = makeFlow(chat: chat, settings: settings)
        flow.probePermission = { false }
        flow.isPermissionGranted = { false }
        flow.permissionResumeAttempts = 2
        flow.pollInterval = 0.001

        flow.start()

        await waitUntil { !settings.screenPermissionRequestPending }
        XCTAssertEqual(settings.onboardingStep, .permission)
        XCTAssertEqual(chat.lastShown?.text, OnboardingFlow.introText)
    }

    // MARK: - Model download

    func testDownloadProgressIsShownWhileTheModelArrives() async {
        let (settings, defaults, suiteName) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        settings.onboardingStep = .test
        let chat = FakeChatPresenter()
        var state = ModelReadinessState.waitingForOllama
        let flow = makeFlow(chat: chat, settings: settings)
        flow.modelState = { state }

        flow.start()
        XCTAssertTrue(chat.lastShown?.text.contains("Waiting for Ollama") ?? false)

        state = .downloading(fraction: 0.42, detail: "2.6 of 6.1 GB")
        flow.modelStateDidChange(state)

        XCTAssertEqual(
            chat.lastShown?.text,
            "Downloading local LLM model — 42% (2.6 of 6.1 GB). This runs once."
        )
        XCTAssertEqual(chat.lastShown?.autoHide, false)
    }

    func testCheckRunsOnItsOwnOnceTheModelIsReady() async {
        let (settings, defaults, suiteName) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        settings.onboardingStep = .test
        let chat = FakeChatPresenter()
        let scheduler = Scheduler(clock: TestClock())
        var checkReasons: [CheckReason] = []
        var state = ModelReadinessState.downloading(fraction: 0.9, detail: nil)
        let flow = makeFlow(
            chat: chat,
            scheduler: scheduler,
            settings: settings,
            runCheck: { reason in
                checkReasons.append(reason)
                return Decision(tool: .set_angry, snoozeMinutes: nil, message: "Close it!")
            }
        )
        flow.modelState = { state }

        flow.start()
        XCTAssertTrue(checkReasons.isEmpty)

        state = .ready
        flow.modelStateDidChange(state)

        await waitUntil { checkReasons.count == 1 }
        guard case .onboarding = checkReasons[0] else {
            return XCTFail("Expected the onboarding check reason")
        }
        XCTAssertEqual(scheduler.state, .angry)
        XCTAssertNil(chat.onTap)
    }

    // MARK: - Finishing

    func testACaughtFirstCheckEndsWithTheDemonstration() async {
        let (settings, defaults, suiteName) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        settings.intervalMinutes = 12
        settings.onboardingStep = .test
        let chat = FakeChatPresenter()
        let scheduler = Scheduler(clock: TestClock())
        var didFinish = false
        let flow = makeFlow(
            chat: chat,
            scheduler: scheduler,
            settings: settings,
            runCheck: { _ in
                Decision(tool: .set_angry, snoozeMinutes: nil, message: "Close it!")
            }
        )
        flow.modelState = { .ready }
        flow.onFinished = { didFinish = true }

        flow.start()
        await waitUntil { scheduler.state == .angry }

        scheduler.apply(Decision(tool: .set_idle, snoozeMinutes: nil, message: "Good."))
        flow.schedulerDidChange(to: scheduler.state)

        XCTAssertEqual(settings.onboardingStep, .done)
        XCTAssertTrue(didFinish)
        XCTAssertEqual(
            chat.lastShown?.text,
            "That's how it works. Back to work — next check in 12 minutes."
        )
        XCTAssertEqual(chat.lastShown?.autoHide, true)
        XCTAssertEqual(chat.affordance, .reply)
        XCTAssertNil(chat.onTap)
        XCTAssertNil(chat.onClose)
    }

    /// A clean first check gets the demo as an invitation, never as a gate.
    func testACleanFirstCheckEndsWithAnInvitation() async {
        let (settings, defaults, suiteName) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        settings.intervalMinutes = 10
        settings.onboardingStep = .test
        let chat = FakeChatPresenter()
        let scheduler = Scheduler(clock: TestClock())
        var didFinish = false
        let flow = makeFlow(
            chat: chat,
            scheduler: scheduler,
            settings: settings,
            runCheck: { _ in Decision(tool: .set_idle, snoozeMinutes: nil, message: "") }
        )
        flow.modelState = { .ready }
        flow.onFinished = { didFinish = true }

        flow.start()
        await waitUntil { scheduler.state == .idle }
        flow.schedulerDidChange(to: .idle)

        XCTAssertEqual(settings.onboardingStep, .done)
        XCTAssertTrue(didFinish)
        XCTAssertEqual(
            chat.lastShown?.text,
            "Nothing to shout about. Next check in 10 minutes — open YouTube if you want "
                + "to meet the other side of me."
        )
    }

    func testCloseDuringTheFirstCheckSkipsInsteadOfQuitting() async {
        let (settings, defaults, suiteName) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        settings.onboardingStep = .test
        let chat = FakeChatPresenter()
        var quitCount = 0
        var skipCount = 0
        let flow = makeFlow(
            chat: chat,
            settings: settings,
            quit: { quitCount += 1 },
            skip: { skipCount += 1 }
        )
        flow.modelState = { .waitingForOllama }

        flow.start()
        chat.onClose?()

        XCTAssertEqual(skipCount, 1)
        XCTAssertEqual(quitCount, 0)
    }

    // MARK: - Helpers

    private func makeFlow(
        chat: FakeChatPresenter,
        scheduler: Scheduler? = nil,
        settings: Settings,
        relaunch: @escaping () -> Void = {},
        quit: @escaping () -> Void = {},
        skip: @escaping () -> Void = {},
        runCheck: @escaping (CheckReason) async -> Decision? = { _ in nil }
    ) -> OnboardingFlow {
        OnboardingFlow(
            chat: chat,
            scheduler: scheduler ?? Scheduler(clock: TestClock()),
            settings: settings,
            relaunch: relaunch,
            quit: quit,
            skip: skip,
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
    /// Records every assignment so tests can count how many taps the flow ever asks for.
    var onTap: (() -> Void)? {
        didSet { tapHandlerAssignments.append(onTap != nil) }
    }
    var onClose: (() -> Void)?
    var affordance: BubbleAffordance = .reply
    private(set) var shownMessages: [ShownMessage] = []
    private(set) var askedMessages: [String] = []
    private(set) var tapHandlerAssignments: [Bool] = []
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
