import Foundation

@MainActor
final class Conversation {
    private(set) var turns: [OllamaMessage] = []
    private(set) var lastUserMessage: String?

    private let maxTurns: Int

    init(maxTurns: Int = 12) {
        self.maxTurns = max(1, maxTurns)
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

    func appendAssistant(_ decision: Decision) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try? encoder.encode(decision)
        let content = data.flatMap { String(data: $0, encoding: .utf8) }
            ?? "{\"tool\":\"set_idle\",\"message\":\"\"}"
        turns.append(OllamaMessage(role: "assistant", content: content, images: nil))
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
    }
}
