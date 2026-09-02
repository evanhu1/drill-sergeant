import AppKit
import Foundation

@MainActor
final class AppCoordinator: SchedulerDelegate, DevActions {
    private let settings: Settings

    private var eyesModel: EyesModel?
    private var notchWindow: NotchWindow?
    private var chat: BubbleWindow?
    private var scheduler: Scheduler?
    private var ollama: OllamaClient?
    private var conversation: Conversation?
    private var cursorTracker: CursorTracker?
    private var onboarding: OnboardingFlow?
    private var devToolbar: DevToolbar?
    private var pendingWork: Task<Void, Never>?
    private var lastDecision: OllamaDecisionResult?
    private var pendingReplyCount = 0
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
        notchWindow.onCheckNow = { [weak self] in self?.checkNow() }
        notchWindow.onDeveloper = { [weak self] in self?.showDeveloperToolbar() }
        notchWindow.onQuit = { [weak self] in self?.quit() }
        chat.onVisibilityChange = { notchWindow.setTrayPinned($0) }
        notchWindow.showOnScreen()
        cursorTracker.start()

        if ProcessInfo.processInfo.environment["DS_DEV"] == "1" {
            showDeveloperToolbar()
        }

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

    func quit() {
        Log.info("Quit requested")
        NSApp.terminate(nil)
    }

    var statusText: String {
        guard let scheduler else {
            return "state=starting · next check — · model=\(settings.model)"
        }
        let age = max(0, Int(Date().timeIntervalSince(scheduler.stateChangedAt)))
        let nextCheck = scheduler.nextCheckAt.map {
            DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .short)
        } ?? "—"
        return "state=\(scheduler.state.rawValue) (\(age)s) · next check \(nextCheck) "
            + "· model=\(settings.model)"
    }

    var lastDecisionText: String {
        guard let lastDecision else { return "No decision yet" }
        let message = lastDecision.decision.message
            .replacingOccurrences(of: "\n", with: " ")
        return String(
            format: "%@ — '%@' (%.1fs, field=%@)",
            lastDecision.decision.tool.rawValue,
            message,
            lastDecision.latency,
            lastDecision.sourceField
        )
    }

    func forceState(_ state: CompanionState) {
        scheduler?.debugTransition(to: state)
    }

    func showTestMessage(_ text: String, autoHide: Bool) {
        chat?.onTap = nil
        chat?.show(text, autoHide: autoHide)
    }

    func sendReply(_ text: String) {
        submitReply(text)
    }

    func runCheck() {
        checkNow()
    }

    func captureOnly() async -> String {
        do {
            let screenshot = try await ScreenCapture.capture()
            let directory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/DrillSergeant", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let destination = directory.appendingPathComponent("last-capture.jpg")
            try screenshot.jpegData.write(to: destination, options: .atomic)
            let kilobytes = Int((Double(screenshot.jpegData.count) / 1_024).rounded())
            let window = ActiveWindowInspector.current()
            Log.info("Developer capture saved to \(destination.path)")
            return "\(screenshot.width)x\(screenshot.height), \(kilobytes) KB, \(window.summary)"
        } catch let error as ScreenCaptureError {
            let message = "Capture failed: \(description(of: error))"
            Log.error(message)
            return message
        } catch {
            let message = "Capture failed: \(error.localizedDescription)"
            Log.error(message)
            return message
        }
    }

    func resetOnboarding() {
        settings.onboardingStep = .welcome
        conversation?.reset()
        scheduler?.stop()

        if let onboarding {
            onboarding.start()
        } else if let chat, let scheduler, let ollama {
            startOnboarding(chat: chat, scheduler: scheduler, ollama: ollama)
        }
    }

    func skipOnboarding() {
        settings.onboardingStep = .done
        onboarding?.start()
        onboarding = nil
        installReplyHandler()
        scheduler?.start()
    }

    func setTrayExtended(_ extended: Bool) {
        notchWindow?.setTrayExtended(extended)
    }

    func renderStates() async -> URL {
        let outputURL = StateRenderer.defaultOutputURL
        do {
            let renderedURL = try StateRenderer.render(to: outputURL)
            NSWorkspace.shared.open(renderedURL)
            return renderedURL
        } catch {
            Log.error("State rendering failed: \(error.localizedDescription)")
            return outputURL
        }
    }

    func scheduler(
        _ scheduler: Scheduler,
        didChange state: CompanionState,
        from old: CompanionState
    ) {
        Log.info("State changed: \(old.rawValue) -> \(state.rawValue)")
        eyesModel?.state = state

        let wasOnboarding = onboarding != nil
        onboarding?.schedulerDidChange(to: state)

        if old == .happy,
            state == .idle,
            !wasOnboarding,
            pendingReplyCount == 0,
            chat?.isReplying == false
        {
            chat?.hide()
        }
    }

    func schedulerRequestsCheck(_ scheduler: Scheduler, reason: CheckReason) {
        enqueueModelWork { [weak self, weak scheduler] in
            guard let self, let scheduler else { return }
            let decision = await self.runCheck(reason)
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
                return await self.enqueueCheck(reason)
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
        let reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else { return }
        pendingReplyCount += 1
        chat?.onTap = nil
        chat?.show("…", autoHide: false)
        enqueueModelWork { [weak self] in
            await self?.runReply(reply)
        }
    }

    private func enqueueModelWork(
        _ work: @escaping @MainActor () async -> Void
    ) {
        let previous = pendingWork
        pendingWork = Task { @MainActor in
            _ = await previous?.value
            await work()
        }
    }

    private func enqueueCheck(_ reason: CheckReason) async -> Decision? {
        await withCheckedContinuation { continuation in
            enqueueModelWork { [weak self] in
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: await self.runCheck(reason))
            }
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
            if pendingReplyCount == 0 {
                presentPermissionRequest()
            }
            return idleDecision
        } catch let error as ScreenCaptureError {
            Log.error("Screen capture failed: \(description(of: error))")
            if pendingReplyCount == 0 {
                chat?.show(
                    "I couldn't capture your screen. I'll try again later.",
                    autoHide: true
                )
            }
            return idleDecision
        } catch {
            Log.error("Screen capture failed: \(error.localizedDescription)")
            if pendingReplyCount == 0 {
                chat?.show(
                    "I couldn't capture your screen. I'll try again later.",
                    autoHide: true
                )
            }
            return idleDecision
        }

        let window = ActiveWindowInspector.current()
        Log.info("Active window: \(window.summary)")
        let context = checkContext(scheduler: scheduler, window: window, reason: reason)
        let prompt = PromptBuilder.checkPrompt(context)
        conversation.appendUser(prompt, image: screenshot.base64)

        let messages = modelMessages(conversation: conversation)
        let outcome = await requestDecision(messages: messages, ollama: ollama)
        handle(
            decision: outcome.decision,
            conversation: conversation,
            presentMessage: pendingReplyCount == 0
        )
        if let errorMessage = outcome.errorMessage, pendingReplyCount == 0 {
            showOllamaError(errorMessage)
        }
        return outcome.decision
    }

    private func runReply(_ text: String) async {
        guard let scheduler, let conversation, let ollama else {
            Log.error("Reply received before coordinator finished starting")
            finishReply(with: nil)
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
        let outcome = await requestDecision(messages: messages, ollama: ollama)
        handle(
            decision: outcome.decision,
            conversation: conversation,
            presentMessage: false
        )
        scheduler.apply(outcome.decision)
        finishReply(with: outcome)
    }

    private func requestDecision(
        messages: [OllamaMessage],
        ollama: OllamaClient
    ) async -> DecisionOutcome {
        do {
            let result = try await ollama.decideWithMetadata(messages: messages)
            lastDecision = result
            return DecisionOutcome(
                decision: result.decision,
                errorMessage: nil
            )
        } catch let error as OllamaError {
            Log.error("Ollama decision failed: \(description(of: error))")
            return DecisionOutcome(
                decision: idleDecision,
                errorMessage: "Can't reach Ollama. Make sure it's running and "
                    + "\(settings.model) is installed."
            )
        } catch {
            Log.error("Ollama decision failed: \(error.localizedDescription)")
            return DecisionOutcome(
                decision: idleDecision,
                errorMessage: "Can't reach Ollama. Make sure it's running."
            )
        }
    }

    private func handle(
        decision: Decision,
        conversation: Conversation,
        presentMessage: Bool = true
    ) {
        conversation.appendAssistant(decision)
        Log.info(
            "Decision: tool=\(decision.tool.rawValue), "
                + "snooze=\(decision.snoozeMinutes.map(String.init) ?? "none")"
        )

        guard presentMessage, !decision.message.isEmpty else { return }
        chat?.onTap = nil
        chat?.show(decision.message, autoHide: decision.tool != .set_angry)
    }

    private func finishReply(with outcome: DecisionOutcome?) {
        pendingReplyCount = max(0, pendingReplyCount - 1)
        guard pendingReplyCount == 0 else {
            chat?.show("…", autoHide: false)
            return
        }

        guard let outcome else {
            chat?.hide()
            return
        }
        if let errorMessage = outcome.errorMessage {
            showOllamaError(errorMessage)
        } else if outcome.decision.message.isEmpty {
            chat?.hide()
        } else {
            chat?.onTap = nil
            chat?.show(
                outcome.decision.message,
                autoHide: outcome.decision.tool != .set_angry
            )
        }
    }

    private func showOllamaError(_ message: String) {
        chat?.onTap = nil
        chat?.show(message, autoHide: true)
    }

    private func checkContext(
        scheduler: Scheduler,
        window: ActiveWindowInfo,
        reason: CheckReason
    ) -> CheckContext {
        let now = Date()
        return CheckContext(
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
            content: PromptBuilder.systemPrompt(),
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

    private func showDeveloperToolbar() {
        if let devToolbar {
            devToolbar.show()
            return
        }
        let toolbar = DevToolbar(actions: self)
        devToolbar = toolbar
        toolbar.show()
    }

    private struct DecisionOutcome {
        let decision: Decision
        let errorMessage: String?
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
