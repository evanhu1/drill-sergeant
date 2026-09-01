import AppKit
import Foundation

@MainActor
final class AppCoordinator: SchedulerDelegate {
    private let settings: Settings

    private var eyesModel: EyesModel?
    private var notchWindow: NotchWindow?
    private var chat: BubbleWindow?
    private var scheduler: Scheduler?
    private var ollama: OllamaClient?
    private var conversation: Conversation?
    private var cursorTracker: CursorTracker?
    private var onboarding: OnboardingFlow?
    private var hasStarted = false

    init() {
        settings = .shared
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        let eyesModel = EyesModel()
        let notchWindow = NotchWindow(eyesModel: eyesModel)
        let initialGeometry = notchWindow.geometry
        let chat = BubbleWindow { [weak notchWindow] in
            notchWindow?.geometry ?? initialGeometry
        }
        let scheduler = Scheduler(
            clock: SystemClock(),
            intervalMinutes: settings.intervalMinutes
        )
        let ollama = OllamaClient(
            baseURL: settings.ollamaBaseURL,
            model: settings.model
        )
        let conversation = Conversation()
        let cursorTracker = CursorTracker(
            eyesModel: eyesModel,
            windowProvider: { [weak notchWindow] in notchWindow }
        )

        self.eyesModel = eyesModel
        self.notchWindow = notchWindow
        self.chat = chat
        self.scheduler = scheduler
        self.ollama = ollama
        self.conversation = conversation
        self.cursorTracker = cursorTracker

        scheduler.delegate = self
        notchWindow.onSetGoal = { [weak self] in self?.promptForGoal() }
        notchWindow.onCheckNow = { [weak self] in self?.checkNow() }
        notchWindow.onQuit = { [weak self] in self?.quit() }
        notchWindow.showOnScreen()

        Log.info(
            "App started; onboarding=\(settings.onboardingStep.rawValue), "
                + "interval=\(settings.intervalMinutes)m, model=\(settings.model)"
        )

        if settings.onboardingStep == .done {
            installReplyHandler()
            scheduler.start()
        } else {
            startOnboarding(chat: chat, scheduler: scheduler, ollama: ollama)
        }
    }

    func relaunch() {
        let process = Process()
        let bundleURL = Bundle.main.bundleURL

        if bundleURL.pathExtension.localizedCaseInsensitiveCompare("app") == .orderedSame {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-n", bundleURL.path]
        } else {
            guard let executableURL = Bundle.main.executableURL else {
                Log.error("Relaunch failed: current executable path is unavailable")
                chat?.show("I couldn't restart. Quit and open me again.", autoHide: false)
                return
            }
            process.executableURL = executableURL
            process.arguments = Array(CommandLine.arguments.dropFirst())
        }

        do {
            try process.run()
            Log.info("Started replacement process for relaunch")
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                NSApp.terminate(nil)
            }
        } catch {
            Log.error("Relaunch failed: \(error.localizedDescription)")
            chat?.show("I couldn't restart. Quit and open me again.", autoHide: false)
        }
    }

    func checkNow() {
        Log.info("Manual check requested")
        scheduler?.checkNow()
    }

    func promptForGoal() {
        guard let chat else { return }
        chat.onTap = nil
        chat.onReply = { [weak self] goal in
            guard let self else { return }
            settings.goal = goal
            conversation?.reset()
            Log.info("Goal updated; conversation reset")
            installReplyHandler()
            chat.hide()
        }
        chat.ask("What are you working on?")
    }

    func quit() {
        Log.info("Quit requested")
        NSApp.terminate(nil)
    }

    func scheduler(
        _ scheduler: Scheduler,
        didChange state: CompanionState,
        from old: CompanionState
    ) {
        Log.info("State changed: \(old.rawValue) -> \(state.rawValue)")
        eyesModel?.state = state

        if state == .watching || state == .angry {
            cursorTracker?.start()
        } else {
            cursorTracker?.stop()
        }

        let wasOnboarding = onboarding != nil
        onboarding?.schedulerDidChange(to: state)

        if old == .happy, state == .idle, !wasOnboarding, chat?.isReplying == false {
            chat?.hide()
        }
    }

    func schedulerRequestsCheck(_ scheduler: Scheduler, reason: CheckReason) {
        Task { [weak self, weak scheduler] in
            guard let self, let scheduler else { return }
            let decision = await runCheck(reason)
            scheduler.apply(decision)
        }
    }

    private func startOnboarding(
        chat: BubbleWindow,
        scheduler: Scheduler,
        ollama: OllamaClient
    ) {
        let onboarding = OnboardingFlow(
            chat: chat,
            scheduler: scheduler,
            settings: settings,
            ollama: ollama,
            relaunch: { [weak self] in self?.relaunch() },
            runCheck: { [weak self] reason in
                guard let self else { return nil }
                return await self.runCheck(reason)
            }
        )
        onboarding.onFinished = { [weak self, weak onboarding] in
            guard let self, self.onboarding === onboarding else { return }
            self.onboarding = nil
            self.installReplyHandler()
            Log.info("Onboarding finished")
        }
        self.onboarding = onboarding
        onboarding.start()
    }

    private func installReplyHandler() {
        chat?.onTap = nil
        chat?.onReply = { [weak self] text in
            self?.submitReply(text)
        }
    }

    private func submitReply(_ text: String) {
        Task { [weak self] in
            await self?.runReply(text)
        }
    }

    private func runCheck(_ reason: CheckReason) async -> Decision {
        guard let scheduler, let conversation, let ollama else {
            Log.error("Check requested before coordinator finished starting")
            return idleDecision
        }

        Log.info("Starting \(description(of: reason)) check")
        let screenshot: Screenshot
        do {
            screenshot = try await ScreenCapture.capture()
            Log.info(
                "Captured \(screenshot.width)x\(screenshot.height) screenshot "
                    + "(\(screenshot.jpegData.count) bytes)"
            )
        } catch ScreenCaptureError.permissionDenied {
            Log.warn("Screen capture permission is not granted")
            presentPermissionRequest()
            return idleDecision
        } catch let error as ScreenCaptureError {
            Log.error("Screen capture failed: \(description(of: error))")
            chat?.show("I couldn't capture your screen. I'll try again later.", autoHide: true)
            return idleDecision
        } catch {
            Log.error("Screen capture failed: \(error.localizedDescription)")
            chat?.show("I couldn't capture your screen. I'll try again later.", autoHide: true)
            return idleDecision
        }

        let window = ActiveWindowInspector.current()
        Log.info("Active window: \(window.summary)")
        let context = checkContext(scheduler: scheduler, window: window, reason: reason)
        let prompt = PromptBuilder.checkPrompt(context)
        conversation.appendUser(prompt, image: screenshot.base64)

        let messages = modelMessages(conversation: conversation)
        let decision = await requestDecision(messages: messages, ollama: ollama)
        handle(decision: decision, conversation: conversation)
        return decision
    }

    private func runReply(_ text: String) async {
        guard let scheduler, let conversation, let ollama else {
            Log.error("Reply received before coordinator finished starting")
            return
        }

        conversation.recordHumanReply(text)
        let window = ActiveWindowInspector.current()
        let context = checkContext(scheduler: scheduler, window: window, reason: .manual)
        let prompt = PromptBuilder.replyPrompt(text, ctx: context)
        var turns = conversation.turns
        if let lastIndex = turns.indices.last {
            turns[lastIndex] = OllamaMessage(role: "user", content: prompt, images: nil)
        }

        Log.info("Sending user reply to Ollama; state=\(scheduler.state.rawValue)")
        let messages = [systemMessage()] + turns
        let decision = await requestDecision(messages: messages, ollama: ollama)
        handle(decision: decision, conversation: conversation)
        scheduler.apply(decision)
    }

    private func requestDecision(
        messages: [OllamaMessage],
        ollama: OllamaClient
    ) async -> Decision {
        do {
            return try await ollama.decide(messages: messages)
        } catch let error as OllamaError {
            Log.error("Ollama decision failed: \(description(of: error))")
            chat?.onTap = nil
            chat?.show(
                "Can't reach Ollama. Make sure it's running and \(settings.model) is installed.",
                autoHide: true
            )
            return idleDecision
        } catch {
            Log.error("Ollama decision failed: \(error.localizedDescription)")
            chat?.onTap = nil
            chat?.show("Can't reach Ollama. Make sure it's running.", autoHide: true)
            return idleDecision
        }
    }

    private func handle(decision: Decision, conversation: Conversation) {
        conversation.appendAssistant(decision)
        Log.info(
            "Decision: tool=\(decision.tool.rawValue), "
                + "snooze=\(decision.snoozeMinutes.map(String.init) ?? "none")"
        )

        guard !decision.message.isEmpty else { return }
        chat?.onTap = nil
        chat?.show(decision.message, autoHide: decision.tool != .set_angry)
    }

    private func checkContext(
        scheduler: Scheduler,
        window: ActiveWindowInfo,
        reason: CheckReason
    ) -> CheckContext {
        let now = Date()
        return CheckContext(
            goal: settings.goal,
            state: scheduler.state,
            previousState: scheduler.previousState,
            stateAge: max(0, now.timeIntervalSince(scheduler.stateChangedAt)),
            window: window,
            lastUserMessage: conversation?.lastUserMessage,
            now: now,
            reason: reason
        )
    }

    private func modelMessages(conversation: Conversation) -> [OllamaMessage] {
        [systemMessage()] + conversation.turns
    }

    private func systemMessage() -> OllamaMessage {
        OllamaMessage(
            role: "system",
            content: PromptBuilder.systemPrompt(goal: settings.goal),
            images: nil
        )
    }

    private func presentPermissionRequest() {
        chat?.show(
            "I need Screen Recording permission. Click here to grant it.",
            autoHide: false
        )
        chat?.onTap = { [weak self] in
            guard let self else { return }
            if ScreenPermission.request() || ScreenPermission.isGranted() {
                chat?.show(
                    "Permission granted. Click here to restart me.",
                    autoHide: false
                )
                chat?.onTap = { [weak self] in self?.relaunch() }
            } else {
                ScreenPermission.openSystemSettings()
            }
        }
    }

    private var idleDecision: Decision {
        Decision(tool: .set_idle, snoozeMinutes: nil, message: "")
    }

    private func description(of reason: CheckReason) -> String {
        switch reason {
        case .scheduled: return "scheduled"
        case .angryPoll: return "angry poll"
        case .manual: return "manual"
        case .onboarding: return "onboarding"
        }
    }

    private func description(of error: ScreenCaptureError) -> String {
        switch error {
        case .permissionDenied: return "permission denied"
        case .noDisplay: return "no display"
        case let .failed(message): return message
        }
    }

    private func description(of error: OllamaError) -> String {
        switch error {
        case .unreachable: return "unreachable"
        case let .modelMissing(model): return "model missing: \(model)"
        case let .badResponse(message): return "bad response: \(message)"
        case let .http(status): return "HTTP \(status)"
        }
    }
}
