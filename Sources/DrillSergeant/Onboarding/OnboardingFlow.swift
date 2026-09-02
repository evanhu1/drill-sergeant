import Foundation

enum OnboardingStep: String, Codable {
    case welcome
    case permission
    case relaunch
    case directCapturePermission
    case test
    case done
}

@MainActor
final class OnboardingFlow {
    var onFinished: (() -> Void)?

    var isPermissionGranted: () -> Bool = ScreenPermission.isGranted
    var probePermission: () async -> Bool = ScreenPermission.probe
    var requestPermission: () -> Bool = ScreenPermission.request
    var openPermissionSettings: () -> Void = ScreenPermission.openSystemSettings
    var requestDirectCapturePermission: () async -> Bool = {
        do {
            _ = try await ScreenCapture.capture()
            return true
        } catch {
            Log.warn("Direct screen capture permission probe failed: \(error.localizedDescription)")
            return false
        }
    }
    var isYouTubeOpen: () -> Bool = {
        ActiveWindowInspector.current().looksLikeYouTube
    }
    var isOllamaReady: () async -> Bool
    var pollInterval: TimeInterval = 2
    var permissionResumeAttempts = 5

    private let chat: ChatPresenter
    private let scheduler: Scheduler
    private let settings: Settings
    private let relaunchHandler: () -> Void
    private let quitHandler: () -> Void
    private let runCheck: (CheckReason) async -> Decision?

    private var pollingTask: Task<Void, Never>?
    private var checkTask: Task<Void, Never>?
    private var permissionRequestAttempts = 0
    private var hasTriggeredTestCheck = false
    private var isRunningTestCheck = false
    private var didNotifyFinished = false

    init(
        chat: ChatPresenter,
        scheduler: Scheduler,
        settings: Settings,
        ollama: OllamaClient,
        relaunch: @escaping () -> Void,
        quit: @escaping () -> Void,
        runCheck: @escaping (CheckReason) async -> Decision?
    ) {
        self.chat = chat
        self.scheduler = scheduler
        self.settings = settings
        relaunchHandler = relaunch
        quitHandler = quit
        self.runCheck = runCheck
        isOllamaReady = {
            guard await ollama.isReachable() else { return false }
            return (try? await ollama.hasModel()) == true
        }
    }

    /// Resumes onboarding from the last persisted step.
    func start() {
        cancelTasks()
        clearChatHandlers()
        chat.onClose = settings.onboardingStep == .done ? nil : quitHandler

        switch settings.onboardingStep {
        case .welcome:
            presentWelcome()
        case .permission:
            if settings.screenPermissionRequestPending {
                resumePermissionRequest()
            } else {
                beginPermissionStep()
            }
        case .relaunch:
            resumePermissionRequest()
        case .directCapturePermission:
            if settings.directCapturePermissionRequestPending {
                resumeDirectCapturePermissionRequest()
            } else {
                presentDirectCapturePermissionStep()
            }
        case .test:
            beginTestStep()
        case .done:
            notifyFinished()
        }
    }

    /// Receives scheduler changes while the onboarding test is active.
    func schedulerDidChange(to state: CompanionState) {
        guard settings.onboardingStep == .test, hasTriggeredTestCheck else { return }
        guard state == .happy || state == .idle else { return }
        finish()
    }

    private func presentWelcome() {
        chat.affordance = .click
        chat.show(
            "Drill Sergeant reporting. I watch your screen and shout at you when you slack "
                + "off. Everything runs on a local AI model, and your data never leaves your Mac.",
            autoHide: false
        )
        chat.onTap = { [weak self] in
            guard let self else { return }
            clearChatHandlers()
            settings.onboardingStep = .permission
            beginPermissionStep()
        }
    }

    /// The step is always shown. Skipping it on `isPermissionGranted()` meant it silently
    /// vanished whenever the grant was inherited rather than this build's own.
    private func beginPermissionStep() {
        clearChatHandlers()
        chat.affordance = .click
        settings.onboardingStep = .permission
        permissionRequestAttempts = 0
        chat.show(
            "Now I need Screen Recording permission to see your screen. "
                + "Click this bubble to grant it.",
            autoHide: false
        )
        chat.onTap = { [weak self] in
            self?.requestScreenPermission()
        }
    }

    /// Nothing is asked for until the user presses the bubble.
    private func requestScreenPermission() {
        permissionRequestAttempts += 1
        let attempt = permissionRequestAttempts
        settings.screenPermissionRequestPending = true
        checkTask?.cancel()
        checkTask = Task { [weak self] in
            guard let self else { return }
            if await probePermission() {
                // Capture works in this process, so there is nothing to restart for.
                permissionIsWorking()
                return
            }
            _ = requestPermission()
            guard !Task.isCancelled else { return }
            if attempt >= 2, !isPermissionGranted() {
                openPermissionSettings()
            }
            startPermissionPolling()
        }
    }

    /// After the prompt, watch for the answer. A grant that macOS has recorded but that capture
    /// cannot use yet is the case that needs a relaunch.
    private func startPermissionPolling() {
        pollingTask?.cancel()
        let interval = pollInterval
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard await Self.sleep(for: interval) else { return }
                guard let self else { return }
                if await probePermission() {
                    permissionIsWorking()
                    return
                }
                if isPermissionGranted() {
                    permissionNeedsRelaunch()
                    return
                }
            }
        }
    }

    private func permissionIsWorking() {
        guard settings.onboardingStep == .permission
            || settings.onboardingStep == .relaunch else { return }
        pollingTask?.cancel()
        pollingTask = nil
        settings.screenPermissionRequestPending = false
        presentDirectCapturePermissionStep()
    }

    private func permissionNeedsRelaunch() {
        guard settings.onboardingStep == .permission else { return }
        pollingTask?.cancel()
        pollingTask = nil
        settings.onboardingStep = .relaunch
        presentRelaunchStep()
    }

    /// Keep the bubble visible while a replacement process resolves the permission request that
    /// caused the old process to quit. The probe decides whether to advance, ask for a restart,
    /// or return to the permission step after a denial.
    private func resumePermissionRequest() {
        clearChatHandlers()
        chat.show("Checking Screen Recording permission…", autoHide: false)
        checkTask?.cancel()
        let attempts = max(1, permissionResumeAttempts)
        let interval = pollInterval
        checkTask = Task { [weak self] in
            guard let self else { return }
            for attempt in 1...attempts {
                if await probePermission() {
                    guard !Task.isCancelled else { return }
                    Log.info("Screen Recording permission works after relaunch")
                    permissionIsWorking()
                    return
                }
                guard !Task.isCancelled else { return }
                if attempt < attempts {
                    guard await Self.sleep(for: interval) else { return }
                }
            }

            if isPermissionGranted() {
                Log.info("Screen Recording grant is recorded but still requires a restart")
                settings.onboardingStep = .relaunch
                presentRelaunchStep()
            } else {
                Log.info("Screen Recording permission was not granted after relaunch")
                permissionRequestDidNotComplete()
            }
        }
    }

    private func permissionRequestDidNotComplete() {
        settings.screenPermissionRequestPending = false
        beginPermissionStep()
    }

    private func presentRelaunchStep() {
        clearChatHandlers()
        chat.affordance = .click
        chat.show(
            "Permission granted. I have to restart to use it. Click here to restart.",
            autoHide: false
        )
        chat.onTap = { [weak self] in
            self?.relaunchHandler()
        }
    }

    /// macOS separately asks whether the app may capture without presenting its window picker.
    /// Trigger that prompt only after an explicit tap, then discard the probe screenshot.
    private func presentDirectCapturePermissionStep() {
        clearChatHandlers()
        chat.affordance = .click
        settings.onboardingStep = .directCapturePermission
        settings.directCapturePermissionRequestPending = false
        chat.show(
            "One more permission: I need direct screen access so I can check your active window "
                + "automatically without making you pick it every time. Click this bubble to grant it.",
            autoHide: false
        )
        chat.onTap = { [weak self] in
            self?.beginDirectCapturePermissionRequest()
        }
    }

    private func beginDirectCapturePermissionRequest() {
        settings.directCapturePermissionRequestPending = true
        runDirectCapturePermissionRequest(clearPendingOnFailure: false)
    }

    private func resumeDirectCapturePermissionRequest() {
        clearChatHandlers()
        chat.show("Checking direct screen access…", autoHide: false)
        runDirectCapturePermissionRequest(clearPendingOnFailure: true)
    }

    private func runDirectCapturePermissionRequest(clearPendingOnFailure: Bool) {
        chat.onReply = nil
        chat.onTap = nil
        checkTask?.cancel()
        checkTask = Task { [weak self] in
            guard let self else { return }
            let granted = await requestDirectCapturePermission()
            guard !Task.isCancelled else { return }
            if granted {
                settings.directCapturePermissionRequestPending = false
                Log.info("Direct screen capture permission works")
                beginTestStep()
            } else {
                if clearPendingOnFailure {
                    settings.directCapturePermissionRequestPending = false
                }
                presentDirectCapturePermissionRetry()
            }
        }
    }

    private func presentDirectCapturePermissionRetry() {
        clearChatHandlers()
        chat.affordance = .click
        chat.show(
            "Direct screen access still isn't available. Approve Drill Sergeant in System "
                + "Settings, then click this bubble to try again.",
            autoHide: false
        )
        chat.onTap = { [weak self] in
            self?.beginDirectCapturePermissionRequest()
        }
    }

    private func beginTestStep() {
        clearChatHandlers()
        settings.onboardingStep = .test
        settings.screenPermissionRequestPending = false
        settings.directCapturePermissionRequestPending = false
        hasTriggeredTestCheck = false
        isRunningTestCheck = false
        chat.show("Getting the screen test ready…", autoHide: false)
        startOllamaPolling()
    }

    private func startOllamaPolling() {
        pollingTask?.cancel()
        let checkOllama = isOllamaReady
        let interval = pollInterval * 5
        let model = settings.model
        pollingTask = Task { [weak self] in
            var displayedError = false
            while !Task.isCancelled {
                if await checkOllama() {
                    self?.ollamaDidBecomeReady()
                    return
                }

                if !displayedError {
                    self?.chat.show(
                        "I can't reach Ollama or the model \(model) is missing. Run install.sh "
                            + "again, or `ollama pull \(model)`. I'll keep checking.",
                        autoHide: false
                    )
                    displayedError = true
                }
                guard await Self.sleep(for: interval) else { return }
            }
        }
    }

    private func ollamaDidBecomeReady() {
        guard settings.onboardingStep == .test else { return }
        pollingTask = nil
        chat.onTap = nil
        chat.onReply = nil
        chat.affordance = .display
        chat.show("Let's test it, open up YouTube.", autoHide: false)
        scheduler.enterWatching()
        startYouTubePolling()
    }

    private func startYouTubePolling() {
        pollingTask?.cancel()
        let checkYouTube = isYouTubeOpen
        let interval = pollInterval
        let reminderAfter = pollInterval * 90
        pollingTask = Task { [weak self] in
            var elapsed: TimeInterval = 0
            var displayedReminder = false

            while !Task.isCancelled {
                if checkYouTube() {
                    self?.beginTestCheck()
                    return
                }
                if !displayedReminder, elapsed >= reminderAfter {
                    self?.chat.show(
                        "Still waiting. Open YouTube so I can show you what happens.",
                        autoHide: false
                    )
                    displayedReminder = true
                }
                guard await Self.sleep(for: interval) else { return }
                elapsed += max(0, interval)
            }
        }
    }

    private func beginTestCheck() {
        guard settings.onboardingStep == .test, !isRunningTestCheck else { return }
        pollingTask?.cancel()
        pollingTask = nil
        chat.onReply = nil
        hasTriggeredTestCheck = true
        isRunningTestCheck = true

        checkTask = Task { [weak self] in
            guard let self else { return }
            let decision = await runCheck(.onboarding)
            guard !Task.isCancelled else { return }
            checkTask = nil
            isRunningTestCheck = false

            guard let decision else {
                hasTriggeredTestCheck = false
                ollamaDidBecomeReady()
                return
            }
            scheduler.apply(decision)
        }
    }

    private func finish() {
        guard settings.onboardingStep != .done else { return }
        cancelTasks()
        clearChatHandlers()
        settings.onboardingStep = .done
        chat.onClose = nil
        chat.affordance = .reply
        chat.show(
            "That's how it works. Back to work — next check in "
                + "\(settings.intervalMinutes) minutes.",
            autoHide: true
        )
        notifyFinished()
    }

    private func notifyFinished() {
        guard !didNotifyFinished else { return }
        didNotifyFinished = true
        onFinished?()
    }

    private func cancelTasks() {
        pollingTask?.cancel()
        checkTask?.cancel()
        pollingTask = nil
        checkTask = nil
    }

    private func clearChatHandlers() {
        chat.onReply = nil
        chat.onTap = nil
        chat.affordance = .display
    }

    private static func sleep(for interval: TimeInterval) async -> Bool {
        let nanoseconds = UInt64(max(0.001, interval) * 1_000_000_000)
        do {
            try await Task.sleep(nanoseconds: nanoseconds)
            return !Task.isCancelled
        } catch {
            return false
        }
    }
}
