import Foundation

enum OnboardingStep: String, Codable {
    case welcome
    case permission
    case relaunch
    case test
    case done
}

@MainActor
final class OnboardingFlow {
    var onFinished: (() -> Void)?

    var isPermissionGranted: () -> Bool = ScreenPermission.isGranted
    var requestPermission: () -> Bool = ScreenPermission.request
    var openPermissionSettings: () -> Void = ScreenPermission.openSystemSettings
    var isYouTubeOpen: () -> Bool = {
        ActiveWindowInspector.current().looksLikeYouTube
    }
    var isOllamaReady: () async -> Bool
    var pollInterval: TimeInterval = 2

    private let chat: ChatPresenter
    private let scheduler: Scheduler
    private let settings: Settings
    private let relaunchHandler: () -> Void
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
        runCheck: @escaping (CheckReason) async -> Decision?
    ) {
        self.chat = chat
        self.scheduler = scheduler
        self.settings = settings
        relaunchHandler = relaunch
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

        switch settings.onboardingStep {
        case .welcome:
            presentWelcome()
        case .permission:
            beginPermissionStep()
        case .relaunch:
            if isPermissionGranted() {
                beginTestStep()
            } else {
                presentRelaunchStep()
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

    private func beginPermissionStep() {
        clearChatHandlers()
        if isPermissionGranted() {
            beginTestStep()
            return
        }

        settings.onboardingStep = .permission
        permissionRequestAttempts = 0
        chat.show(
            "Good. Now I need Screen Recording permission to see your screen. "
                + "Click this bubble to grant it.",
            autoHide: false
        )
        chat.onTap = { [weak self] in
            self?.requestScreenPermission()
        }
        startPermissionPolling()
    }

    private func requestScreenPermission() {
        permissionRequestAttempts += 1
        if requestPermission() || isPermissionGranted() {
            permissionDidBecomeGranted()
        } else if permissionRequestAttempts >= 2 {
            openPermissionSettings()
        }
    }

    private func startPermissionPolling() {
        pollingTask?.cancel()
        let checkPermission = isPermissionGranted
        let interval = pollInterval
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard await Self.sleep(for: interval) else { return }
                guard checkPermission() else { continue }
                self?.permissionDidBecomeGranted()
                return
            }
        }
    }

    private func permissionDidBecomeGranted() {
        guard settings.onboardingStep == .permission else { return }
        pollingTask?.cancel()
        pollingTask = nil
        settings.onboardingStep = .relaunch
        presentRelaunchStep()
    }

    private func presentRelaunchStep() {
        clearChatHandlers()
        chat.show(
            "Permission granted. I have to restart to use it. Click here to restart.",
            autoHide: false
        )
        chat.onTap = { [weak self] in
            self?.relaunchHandler()
        }
    }

    private func beginTestStep() {
        clearChatHandlers()
        settings.onboardingStep = .test
        hasTriggeredTestCheck = false
        isRunningTestCheck = false
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
        chat.onReply = { [weak self] reply in
            guard reply.trimmingCharacters(in: .whitespacesAndNewlines)
                .localizedCaseInsensitiveCompare("done") == .orderedSame else {
                return
            }
            self?.beginTestCheck()
        }
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
