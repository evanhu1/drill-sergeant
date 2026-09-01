// STUB: implemented in wave 2
import Foundation

enum OnboardingStep: String, Codable {
    case welcome
    case goal
    case permission
    case relaunch
    case test
    case done
}

@MainActor
final class OnboardingFlow {
    var onFinished: (() -> Void)?

    private let chat: ChatPresenter
    private let scheduler: Scheduler
    private let settings: Settings
    private let ollama: OllamaClient
    private let relaunchHandler: () -> Void
    private let runCheck: (CheckReason) async -> Decision?

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
        self.ollama = ollama
        relaunchHandler = relaunch
        self.runCheck = runCheck
    }

    func start() {}
}
