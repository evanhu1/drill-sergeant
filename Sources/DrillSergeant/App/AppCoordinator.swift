import AppKit
import Foundation
import SwiftUI

@MainActor
final class AppCoordinator: SchedulerDelegate, DevActions {
    private let settings: Settings
    private let traceWriter: CheckTrace
    private let launchReplacement: (RelaunchCommand) throws -> Void

    private var eyesModel: EyesModel?
    private var notchWindow: NotchWindow?
    private var chat: BubbleWindow?
    private var scheduler: Scheduler?
    private var ollama: OllamaClient?
    private var modelReadiness: ModelReadiness?
    private var conversation: Conversation?
    private var cursorTracker: CursorTracker?
    private var onboarding: OnboardingFlow?
    private var devToolbar: DevToolbar?
    private var pendingWork: Task<Void, Never>?
    private var lastDecision: OllamaDecisionResult?
    private var pendingReplyCount = 0
    private var hasStarted = false
    private var isRelaunchScheduled = false
    private var isIntentionalQuit = false

    convenience init() {
        self.init(settings: .shared, launchReplacement: Relauncher.launch)
    }

    init(
        settings: Settings,
        launchReplacement: @escaping (RelaunchCommand) throws -> Void
    ) {
        self.settings = settings
        traceWriter = CheckTrace()
        self.launchReplacement = launchReplacement
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
            intervalMinutes: settings.intervalMinutes,
            workHours: settings.workHours
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

        // Started before anything else: the model download is the long pole, and it should
        // run while the user reads the first bubble rather than after.
        let modelReadiness = ModelReadiness(ollama: ollama)
        modelReadiness.onChange = { [weak self] state in
            self?.modelReadinessDidChange(state)
        }

        self.eyesModel = eyesModel
        self.notchWindow = notchWindow
        self.chat = chat
        self.scheduler = scheduler
        self.ollama = ollama
        self.modelReadiness = modelReadiness
        self.conversation = conversation
        self.cursorTracker = cursorTracker
        modelReadiness.start()

        scheduler.delegate = self
        notchWindow.onCheckNow = { [weak self] in self?.checkNow() }
        notchWindow.onDeveloper = { [weak self] in self?.showDeveloperToolbar() }
        notchWindow.onQuit = { [weak self] in self?.quit() }
        notchWindow.onTrayExtensionChange = { [weak self] extended in
            self?.updateCursorTracking(isTrayExtended: extended)
        }
        chat.onVisibilityChange = { [weak eyesModel] visible in
            notchWindow.setTrayPinned(visible)
            guard let eyesModel else { return }
            if visible {
                eyesModel.attention = .bubble
            } else if eyesModel.attention != .cursor {
                eyesModel.attention = .cursor
            }
        }
        chat.onInputStateChange = { [weak eyesModel] isOpen in
            eyesModel?.attention = isOpen ? .typing : .cursor
        }
        notchWindow.showOnScreen()
        updateCursorTracking(isTrayExtended: notchWindow.isTrayExtended)

        if ProcessInfo.processInfo.environment["DS_DEV"] == "1" {
            showDeveloperToolbar()
        }

        Log.info(
            "App started; onboarding=\(settings.onboardingStep.rawValue), "
                + "interval=\(settings.intervalMinutes)m, "
                + "workHours=\(settings.workHours.promptDescription), model=\(settings.model)"
        )

        if settings.onboardingStep == .done {
            installReplyHandler()
            if settings.screenPermissionRequestPending {
                resumeAfterScreenPermissionRequest()
            } else {
                scheduler.start()
                verifyScreenPermission()
            }
            LoginItem.enable()
        } else {
            startOnboarding(chat: chat, scheduler: scheduler)
        }
    }

    func relaunch() {
        guard scheduleRelaunch() else { return }
        NSApp.terminate(nil)
    }

    func checkNow() {
        Log.info("Manual check requested")
        scheduler?.checkNow()
    }

    func quit() {
        Log.info("Quit requested")
        prepareForIntentionalQuit()
        NSApp.terminate(nil)
    }

    func prepareForIntentionalQuit() {
        isIntentionalQuit = true
        settings.clearPendingPermissionRequests()
    }

    func applicationShouldTerminate(
        quitReason: AEEventID?
    ) -> NSApplication.TerminateReply {
        guard !isIntentionalQuit,
              !TerminationReason.endsLoginSession(quitReason),
              settings.hasPendingPermissionRequest else {
            return .terminateNow
        }

        Log.info("External quit received during a permission request")
        return scheduleRelaunch() ? .terminateNow : .terminateCancel
    }

    private func scheduleRelaunch() -> Bool {
        if isRelaunchScheduled { return true }
        guard let command = Relauncher.command(
            bundleURL: Bundle.main.bundleURL,
            executableURL: Bundle.main.executableURL,
            arguments: CommandLine.arguments,
            parentProcessID: ProcessInfo.processInfo.processIdentifier,
            environment: ProcessInfo.processInfo.environment
        ) else {
            Log.error("Relaunch failed: current executable path is unavailable")
            chat?.show("I couldn't restart. Click here to try again.", autoHide: false)
            return false
        }

        do {
            try launchReplacement(command)
            isRelaunchScheduled = true
            Log.info("Scheduled replacement process for relaunch")
            return true
        } catch {
            Log.error("Relaunch failed: \(error.localizedDescription)")
            chat?.show("I couldn't restart. Click here to try again.", autoHide: false)
            return false
        }
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
        settings.clearPendingPermissionRequests()
        settings.onboardingStep = .welcome
        conversation?.reset()
        scheduler?.stop()

        if let onboarding {
            onboarding.start()
        } else if let chat, let scheduler {
            startOnboarding(chat: chat, scheduler: scheduler)
        }
    }

    func skipOnboarding() {
        settings.clearPendingPermissionRequests()
        settings.onboardingStep = .done
        onboarding?.start()
        onboarding = nil
        chat?.hide()
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

    func openTraceFolder() {
        do {
            try traceWriter.createDirectoryIfNeeded()
            NSWorkspace.shared.activateFileViewerSelecting([traceWriter.directory])
        } catch {
            Log.error("Could not open trace folder: \(error.localizedDescription)")
        }
    }

    func scheduler(
        _ scheduler: Scheduler,
        didChange state: CompanionState,
        from old: CompanionState
    ) {
        Log.info("State changed: \(old.rawValue) -> \(state.rawValue)")
        withAnimation(.easeInOut(duration: 0.25)) {
            eyesModel?.state = state
        }

        let wasOnboarding = onboarding != nil
        onboarding?.schedulerDidChange(to: state)

        if state == .idle,
            (old == .happy || !scheduler.isActiveNow),
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
        scheduler: Scheduler
    ) {
        let onboarding = OnboardingFlow(
            chat: chat,
            scheduler: scheduler,
            settings: settings,
            relaunch: { [weak self] in self?.relaunch() },
            quit: { [weak self] in self?.quit() },
            skip: { [weak self] in self?.skipOnboarding() },
            runCheck: { [weak self] reason in
                guard let self else { return nil }
                return await self.enqueueCheck(reason)
            }
        )
        onboarding.modelState = { [weak self] in
            self?.modelReadiness?.state ?? .ready
        }
        onboarding.onFinished = { [weak self, weak onboarding] in
            guard let self, self.onboarding === onboarding else { return }
            self.onboarding = nil
            self.installReplyHandler()
            // Registered only once someone has actually finished setup, so a person who
            // quits during onboarding is not left with a login item they never wanted.
            LoginItem.enable()
            Log.info("Onboarding finished")
        }
        self.onboarding = onboarding
        onboarding.start()
    }

    /// Every update ships a new ad-hoc signature, and macOS pins the Screen Recording
    /// grant to the old one. Left alone that reads as allowed while capture fails, and the
    /// user finds out at the next check. Ask at launch instead, so an update stays silent
    /// only when it actually worked.
    private func verifyScreenPermission() {
        Task { @MainActor [weak self] in
            let works = await ScreenPermission.probe()
            guard let self, !works else { return }
            guard settings.onboardingStep == .done, pendingReplyCount == 0 else { return }
            Log.warn("Screen Recording no longer works for this build")
            presentPermissionRequest()
        }
    }

    private func modelReadinessDidChange(_ state: ModelReadinessState) {
        onboarding?.modelStateDidChange(state)
    }

    private func installReplyHandler() {
        chat?.onTap = nil
        chat?.onClose = nil
        chat?.affordance = .reply
        chat?.onReply = { [weak self] text in
            self?.submitReply(text)
        }
    }

    private func updateCursorTracking(isTrayExtended: Bool) {
        if isTrayExtended {
            cursorTracker?.start()
        } else {
            cursorTracker?.stop()
        }
    }

    private func submitReply(_ text: String) {
        let reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else { return }
        pendingReplyCount += 1
        chat?.onTap = nil
        chat?.affordance = .display
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
            logCapture(screenshot)
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
        writeTrace(
            reason: CheckTrace.Reason(reason),
            context: context,
            screenshot: screenshot,
            messages: messages,
            response: outcome.traceResponse
        )
        let decision = decisionAllowedForCheck(outcome.decision)
        handle(
            decision: decision,
            conversationMessages: decision == outcome.decision
                ? outcome.conversationMessages
                : [],
            conversation: conversation,
            presentMessage: pendingReplyCount == 0
        )
        if let errorMessage = outcome.errorMessage, pendingReplyCount == 0 {
            showOllamaError(errorMessage)
        }
        return decision
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
        writeTrace(
            reason: .reply,
            context: context,
            screenshot: nil,
            messages: messages,
            response: outcome.traceResponse
        )
        handle(
            decision: outcome.decision,
            conversationMessages: outcome.conversationMessages,
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
        let startedAt = Date()
        do {
            let result = try await ollama.decideWithTraceMetadata(messages: messages)
            lastDecision = result
            return DecisionOutcome(
                decision: result.decision,
                errorMessage: nil,
                traceResponse: .success(result),
                conversationMessages: result.conversationMessages
            )
        } catch let failure as OllamaDecisionFailure {
            let description = description(of: failure.error)
            Log.error("Ollama decision failed: \(description)")
            return DecisionOutcome(
                decision: idleDecision,
                errorMessage: ollamaErrorMessage,
                traceResponse: .failure(
                    error: description,
                    latency: failure.latency,
                    rawContent: failure.rawContent
                ),
                conversationMessages: []
            )
        } catch let error as OllamaError {
            let description = description(of: error)
            Log.error("Ollama decision failed: \(description)")
            return DecisionOutcome(
                decision: idleDecision,
                errorMessage: ollamaErrorMessage,
                traceResponse: .failure(
                    error: description,
                    latency: Date().timeIntervalSince(startedAt),
                    rawContent: nil
                ),
                conversationMessages: []
            )
        } catch {
            Log.error("Ollama decision failed: \(error.localizedDescription)")
            return DecisionOutcome(
                decision: idleDecision,
                errorMessage: "Can't reach Ollama. Make sure it's running.",
                traceResponse: .failure(
                    error: error.localizedDescription,
                    latency: Date().timeIntervalSince(startedAt),
                    rawContent: nil
                ),
                conversationMessages: []
            )
        }
    }

    private func writeTrace(
        reason: CheckTrace.Reason,
        context: CheckContext,
        screenshot: Screenshot?,
        messages: [OllamaMessage],
        response: CheckTrace.Response
    ) {
        guard settings.tracingEnabled else { return }
        let request = CheckTrace.Request(
            reason: reason,
            time: context.now,
            model: settings.model,
            state: context.state,
            previousState: context.previousState,
            stateAge: context.stateAge,
            capture: screenshot.map(CheckTrace.capture),
            activeWindow: context.window,
            messages: messages
        )
        do {
            let folder = try traceWriter.write(
                request: request,
                response: response,
                screenshotData: screenshot?.jpegData
            )
            Log.info("Wrote check trace \(folder.lastPathComponent)")
        } catch {
            Log.error("Could not write check trace: \(error.localizedDescription)")
        }
    }

    private var ollamaErrorMessage: String {
        "Can't reach Ollama. Make sure it's running and "
            + "\(settings.model) is installed."
    }

    private func handle(
        decision: Decision,
        conversationMessages: [OllamaMessage],
        conversation: Conversation,
        presentMessage: Bool = true
    ) {
        conversation.appendModelExchange(conversationMessages)
        if decision.tool == .save_user_preference {
            saveUserPreference(decision.text)
        }
        if decision.tool == .set_work_hours, let workHours = decision.workHours {
            settings.workHours = workHours
            Log.info("Saved work hours: \(workHours.promptDescription)")
        }
        Log.info(
            "Decision: tool=\(decision.tool.rawValue), "
                + "snooze=\(decision.snoozeMinutes.map(String.init) ?? "none")"
        )

        guard presentMessage, !decision.message.isEmpty else { return }
        chat?.onTap = nil
        chat?.affordance = .reply
        chat?.show(decision.message, autoHide: decision.tool != .set_angry)
    }

    private func finishReply(with outcome: DecisionOutcome?) {
        pendingReplyCount = max(0, pendingReplyCount - 1)
        guard pendingReplyCount == 0 else {
            chat?.affordance = .display
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
            chat?.affordance = .reply
            chat?.show(
                outcome.decision.message,
                autoHide: outcome.decision.tool != .set_angry
            )
        }
    }

    private func showOllamaError(_ message: String) {
        chat?.onTap = nil
        chat?.affordance = .reply
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
            userPreferences: settings.userPreferences,
            workHours: settings.workHours,
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
        chat?.affordance = .click
        chat?.show(
            "I need Screen Recording permission. Click here to grant it.",
            autoHide: false
        )
        chat?.onTap = { [weak self] in
            guard let self else { return }
            settings.screenPermissionRequestPending = true
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

    private func resumeAfterScreenPermissionRequest() {
        chat?.onTap = nil
        chat?.affordance = .display
        chat?.show("Checking Screen Recording permission…", autoHide: false)
        Task { @MainActor [weak self] in
            guard let self else { return }
            if await waitForScreenPermission() {
                settings.screenPermissionRequestPending = false
                scheduler?.start()
                chat?.affordance = .reply
                chat?.show("Permission granted. I'm back on watch.", autoHide: true)
            } else if ScreenPermission.isGranted() {
                chat?.affordance = .click
                chat?.show("Permission granted. Click here to restart me.", autoHide: false)
                chat?.onTap = { [weak self] in self?.relaunch() }
            } else {
                settings.screenPermissionRequestPending = false
                scheduler?.start()
                presentPermissionRequest()
            }
        }
    }

    private func waitForScreenPermission(
        attempts: Int = 5,
        interval: TimeInterval = 2
    ) async -> Bool {
        for attempt in 1...max(1, attempts) {
            if await ScreenPermission.probe() {
                return true
            }
            guard attempt < attempts else { break }
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(max(0.001, interval) * 1_000_000_000)
                )
            } catch {
                return false
            }
        }
        return false
    }

    private var idleDecision: Decision {
        Decision(tool: .set_idle, snoozeMinutes: nil, message: "")
    }

    private func decisionAllowedForCheck(_ decision: Decision) -> Decision {
        guard decision.tool != .set_work_hours else {
            Log.warn("Ignored set_work_hours outside a direct user reply")
            return idleDecision
        }
        return decision
    }

    private func saveUserPreference(_ text: String?) {
        guard let text else {
            Log.warn("save_user_preference was called without text")
            return
        }
        if settings.saveUserPreference(text) {
            Log.info("Saved user preference")
        } else {
            Log.info("Ignored blank or duplicate user preference")
        }
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
        let traceResponse: CheckTrace.Response
        let conversationMessages: [OllamaMessage]
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

    private func logCapture(_ screenshot: Screenshot) {
        let kilobytes = Int((Double(screenshot.jpegData.count) / 1_024).rounded())
        switch screenshot.source {
        case let .window(appName):
            Log.info(
                "Captured window \"\(appName)\" \(screenshot.width)x\(screenshot.height) "
                    + "(\(kilobytes) KB)"
            )
        case .display:
            Log.info(
                "Captured display \(screenshot.width)x\(screenshot.height) "
                    + "(\(kilobytes) KB)"
            )
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
