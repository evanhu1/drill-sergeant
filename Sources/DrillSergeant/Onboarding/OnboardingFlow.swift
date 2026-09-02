import Foundation

enum OnboardingStep: String, Codable {
    /// Kept so installs from older builds still resume. It now runs the permission step.
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
    /// Current model state, supplied by the coordinator's shared `ModelReadiness`.
    var modelState: () -> ModelReadinessState = { .ready }
    var pollInterval: TimeInterval = 2
    var permissionResumeAttempts = 5

    static let introText =
        "Drill Sergeant reporting. I watch your screen and shout when you slack off — "
            + "all on a local AI, so nothing leaves your Mac. "
            + "Click here to let me see your screen."

    private let chat: ChatPresenter
    private let scheduler: Scheduler
    private let settings: Settings
    private let relaunchHandler: () -> Void
    private let quitHandler: () -> Void
    private let skipHandler: () -> Void
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
        relaunch: @escaping () -> Void,
        quit: @escaping () -> Void,
        skip: @escaping () -> Void,
        runCheck: @escaping (CheckReason) async -> Decision?
    ) {
        self.chat = chat
        self.scheduler = scheduler
        self.settings = settings
        relaunchHandler = relaunch
        quitHandler = quit
        skipHandler = skip
        self.runCheck = runCheck
    }

    /// Resumes onboarding from the last persisted step.
    func start() {
        cancelTasks()
        clearChatHandlers()
        chat.onClose = settings.onboardingStep == .done ? nil : quitHandler

        switch settings.onboardingStep {
        case .welcome, .permission:
            if settings.screenPermissionRequestPending {
                resumePermissionRequest()
            } else {
                beginPermissionStep()
            }
        case .relaunch:
            resumePermissionRequest()
        case .directCapturePermission:
            beginDirectCapturePermissionRequest()
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

    /// Receives model download progress so the bubble can show it live.
    func modelStateDidChange(_ state: ModelReadinessState) {
        guard settings.onboardingStep == .test, !hasTriggeredTestCheck else { return }
        if state.isReady {
            modelDidBecomeReady()
        } else {
            chat.show(waitingMessage(for: state), autoHide: false)
        }
    }

    // MARK: - Screen Recording

    /// The intro and the permission ask are one bubble and one click. The step is always
    /// shown; skipping it on `isPermissionGranted()` meant it silently vanished whenever
    /// the grant was inherited rather than this build's own.
    private func beginPermissionStep() {
        clearChatHandlers()
        chat.affordance = .click
        settings.onboardingStep = .permission
        permissionRequestAttempts = 0
        chat.show(Self.introText, autoHide: false)
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
        beginDirectCapturePermissionRequest()
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

    /// The restart is bookkeeping, not a decision, so it happens on its own. It is done once
    /// per install: if the grant still has not propagated afterwards, asking again would only
    /// loop, so the bubble hands the restart back to the user.
    private func presentRelaunchStep() {
        clearChatHandlers()
        guard settings.didAutoRelaunchForPermission else {
            settings.didAutoRelaunchForPermission = true
            chat.show("Permission granted. Restarting myself…", autoHide: false)
            relaunchHandler()
            return
        }

        chat.affordance = .click
        chat.show(
            "Permission granted. I have to restart to use it. Click here to restart.",
            autoHide: false
        )
        chat.onTap = { [weak self] in
            self?.relaunchHandler()
        }
    }

    // MARK: - Direct capture

    /// macOS asks separately whether the app may capture without presenting its window
    /// picker. It follows the first grant with no bubble in between: the user has just
    /// answered one screen prompt and the second belongs to the same request.
    private func beginDirectCapturePermissionRequest() {
        clearChatHandlers()
        settings.onboardingStep = .directCapturePermission
        settings.directCapturePermissionRequestPending = true
        chat.show("Checking direct screen access…", autoHide: false)
        checkTask?.cancel()
        checkTask = Task { [weak self] in
            guard let self else { return }
            let granted = await requestDirectCapturePermission()
            guard !Task.isCancelled else { return }
            settings.directCapturePermissionRequestPending = false
            if granted {
                Log.info("Direct screen capture permission works")
                beginTestStep()
            } else {
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

    // MARK: - First check

    /// The last step runs a real check on whatever is already on screen. Nothing is asked
    /// of the user: by now the model has usually finished downloading in the background,
    /// and the first shout is the demonstration.
    private func beginTestStep() {
        clearChatHandlers()
        settings.onboardingStep = .test
        settings.screenPermissionRequestPending = false
        settings.directCapturePermissionRequestPending = false
        hasTriggeredTestCheck = false
        isRunningTestCheck = false
        chat.onClose = skipHandler

        let state = modelState()
        if state.isReady {
            modelDidBecomeReady()
        } else {
            chat.show(waitingMessage(for: state), autoHide: false)
        }
    }

    private func waitingMessage(for state: ModelReadinessState) -> String {
        switch state {
        case .ready:
            return "Ready."
        case .waitingForOllama:
            return "Waiting for Ollama to start. Open it if it isn't running — I'll wait."
        case let .retrying(reason):
            return "My download stumbled (\(reason)). Trying again."
        case let .downloading(fraction, detail):
            guard let fraction else {
                return "Downloading local LLM model — 6 GB. This runs once."
            }
            let percent = Int((fraction * 100).rounded())
            guard let detail else {
                return "Downloading local LLM model — \(percent)%. This runs once."
            }
            return "Downloading local LLM model — \(percent)% (\(detail)). This runs once."
        }
    }

    private func modelDidBecomeReady() {
        guard settings.onboardingStep == .test, !hasTriggeredTestCheck else { return }
        pollingTask?.cancel()
        pollingTask = nil
        chat.affordance = .display
        chat.show("Let's see what you're up to.", autoHide: false)
        scheduler.enterWatching()
        beginTestCheck()
    }

    private func beginTestCheck() {
        guard settings.onboardingStep == .test, !isRunningTestCheck else { return }
        chat.onTap = nil
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
                // The check could not run. Fall back to waiting for the model.
                hasTriggeredTestCheck = false
                chat.show(waitingMessage(for: modelState()), autoHide: false)
                return
            }
            scheduler.apply(decision)
        }
    }

    /// Ends onboarding. A clean first check gets the YouTube demo as an invitation rather
    /// than a gate — nothing here waits on the user any more.
    private func finish() {
        guard settings.onboardingStep != .done else { return }
        let wasCaught = scheduler.previousState == .angry
        cancelTasks()
        clearChatHandlers()
        settings.onboardingStep = .done
        chat.onClose = nil
        chat.affordance = .reply
        chat.show(
            wasCaught
                ? "That's how it works. Back to work — next check in "
                    + "\(settings.intervalMinutes) minutes."
                : "Nothing to shout about. Next check in \(settings.intervalMinutes) minutes — "
                    + "open YouTube if you want to meet the other side of me.",
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
