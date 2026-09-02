import Foundation

@MainActor
protocol DevActions: AnyObject {
    var statusText: String { get }
    var lastDecisionText: String { get }
    func forceState(_ state: CompanionState)
    func showTestMessage(_ text: String, autoHide: Bool)
    func sendReply(_ text: String)
    func runCheck()
    func captureOnly() async -> String
    func resetOnboarding()
    func skipOnboarding()
    func setTrayExtended(_ extended: Bool)
    func renderStates() async -> URL
}
