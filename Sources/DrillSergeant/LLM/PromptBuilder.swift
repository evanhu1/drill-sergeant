import Foundation

struct CheckContext {
    let goal: String
    let state: CompanionState
    let previousState: CompanionState
    let stateAge: TimeInterval
    let window: ActiveWindowInfo
    let lastUserMessage: String?
    let now: Date
    let reason: CheckReason
}

enum PromptBuilder {
    static func systemPrompt(goal: String) -> String {
        """
        You are Drill Sergeant, a no-nonsense accountability companion living in the user's Mac notch.
        The user works alone and asked you to keep them on task. Their stated goal:
        "\(goal)"

        Every few minutes you receive a screenshot of their screen plus the active window's title.
        Decide whether they are ON TASK for that goal, then respond by calling exactly one tool:
        - set_idle: they are on task (or the screen is ambiguous but plausibly work). Message may be "" to stay quiet, or a short nod.
        - set_angry: they are clearly OFF TASK (YouTube, social media, news, shopping, games, idle scrolling, anything unrelated). Message is a short bark telling them to close it and get back to "\(goal)".
        - snooze: they gave a legitimate reason for a break or a different activity, or asked for time. Set snooze_minutes (1-120). Message acknowledges it briefly.

        Rules:
        - Be blunt, loud, and short: at most 2 sentences, under 160 characters. Drill sergeant tone. No slurs, no insults about the person, no profanity beyond "damn"/"hell".
        - You are on their side. Tough love, never cruel.
        - Reading docs, code, email, chat with coworkers, research related to the goal = on task.
        - If the user replies with a reason, judge it fairly. Do not get talked into endless snoozes: after one snooze, be skeptical.
        - When you are currently angry and the distraction is gone, call set_idle with a brief approving message.
        - Output only the JSON tool call.
        """
    }

    static func checkPrompt(_ context: CheckContext) -> String {
        """
        Screenshot attached.
        Time: \(formatTime(context.now))
        Current state: \(context.state.rawValue) (for \(formatAge(context.stateAge)))
        Previous state: \(context.previousState.rawValue)
        Active window: \(context.window.summary)
        Last thing the user said to you: \(context.lastUserMessage ?? "(nothing yet)")
        Check reason: \(reasonText(context.reason))
        Decide now.
        """
    }

    static func replyPrompt(_ text: String, ctx context: CheckContext) -> String {
        """
        The user replied to you: "\(text)"
        Time: \(formatTime(context.now))
        Current state: \(context.state.rawValue)
        Active window: \(context.window.summary)
        Respond with one tool call.
        """
    }

    private static func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }

    private static func formatAge(_ age: TimeInterval) -> String {
        let totalSeconds = max(0, Int(age))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return seconds > 0
                ? "\(hours)h \(minutes)m \(seconds)s"
                : "\(hours)h \(minutes)m"
        }
        if minutes > 0 {
            return seconds > 0 ? "\(minutes)m \(seconds)s" : "\(minutes)m"
        }
        return "\(seconds)s"
    }

    private static func reasonText(_ reason: CheckReason) -> String {
        switch reason {
        case .scheduled: return "scheduled"
        case .angryPoll: return "angry poll — is the distraction still open?"
        case .manual: return "manual"
        case .onboarding: return "onboarding test"
        }
    }
}
