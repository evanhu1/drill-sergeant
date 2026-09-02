import Foundation

@MainActor
final class Conversation {
    private(set) var turns: [OllamaMessage] = []
    private(set) var lastUserMessage: String?

    private let maxTurns: Int

    init(
        maxTurns: Int? = nil,
        runtimeProfile: RuntimeProfile = .current
    ) {
        self.maxTurns = max(1, maxTurns ?? runtimeProfile.conversationMaxTurns)
    }

    func appendUser(_ text: String, image: String?) {
        for index in turns.indices {
            turns[index].images = nil
        }
        turns.append(
            OllamaMessage(
                role: "user",
                content: text,
                images: image.map { [$0] }
            )
        )
        trim()
    }

    func appendModelExchange(_ messages: [OllamaMessage]) {
        turns.append(contentsOf: messages)
        trim()
    }

    func recordHumanReply(_ text: String) {
        lastUserMessage = text
        appendUser(text, image: nil)
    }

    func reset() {
        turns.removeAll()
        lastUserMessage = nil
    }

    private func trim() {
        if turns.count > maxTurns {
            turns.removeFirst(turns.count - maxTurns)
        }
        while turns.first?.role == "tool" {
            turns.removeFirst()
        }
    }
}
