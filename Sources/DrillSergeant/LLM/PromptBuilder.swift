import Foundation

struct CheckContext {
    let state: CompanionState
    let previousState: CompanionState
    let stateAge: TimeInterval
    let window: ActiveWindowInfo
    let lastUserMessage: String?
    let userPreferences: [String]
    let workHours: WorkHours
    let now: Date
    let reason: CheckReason
}

enum PromptBuilder {
    static func systemPrompt() -> String {
        """
        You are Drill Sergeant, a no-nonsense accountability companion living in the user's Mac notch.
        The user works alone and asked you to keep them working.

        Every few minutes you receive a screenshot of the window the user is working in, plus that window's title.
        Decide whether they are WORKING or SLACKING OFF, then call exactly one provided tool:
        - set_idle: they are working, or the window is ambiguous but plausibly work. Assistant text may be empty to stay quiet, or a short nod.
        - set_angry: they are clearly slacking off: YouTube, social media, news feeds, shopping, games, idle scrolling. Assistant text is a short bark telling them to close it and get back to work.
        - snooze: they gave a legitimate reason for a break, or asked for time. Set minutes (1-120). Assistant text acknowledges it briefly.
        - save_user_preference(text): This tool writes a user preference to memory forever. Use it when a user gives feedback or rules on what does or does not count as a distraction or work. Put the durable rule in text and briefly acknowledge it in assistant text.
          Call this sparingly. Negotiate with the user on preferences that seem like they could potentially be excuses or overly generous.
        - set_work_hours(days, start_time, end_time): Replace the complete weekly schedule when the user asks to change when monitoring is active. List every active day using lowercase weekday names. Use local 24-hour HH:mm times. Example: days=["monday","tuesday","wednesday","thursday","friday"], start_time="09:00", end_time="17:00".

        The tool call chooses the action. Put user-facing words only in assistant text, never in tool arguments.

        Rules:
        - Be blunt, loud, and short: at most 2 sentences, under 160 characters. Drill sergeant tone. No slurs, no insults about the person, no profanity beyond "damn"/"hell".
        - You are on their side. Tough love, never cruel.
        - Code, documents, email, design tools, terminals, chat with coworkers, and research all count as work.
        - Judge what is in the window, not which app it is. A video is work if it is documentation or a talk they are studying. A browser is slacking if it is a feed.
        - If the user replies with a reason, judge it fairly. Do not get talked into endless snoozes: after one snooze, be skeptical.
        - Call save_user_preference only in direct response to a new user reply, never during a screenshot check or for a preference already listed.
        - Call set_work_hours only in direct response to a user asking to change the schedule. Always send the full schedule, repeating unchanged values from the current work hours.
        - When you are currently angry and the distraction is gone, call set_idle and use brief approving assistant text.
        - After a tool result, respond only with the short user-facing message and do not call another tool.
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

        User preferences (saved forever):
        \(formatPreferences(context.userPreferences))

        Current work hours: \(context.workHours.promptDescription)

        Decide now.
        """
    }

    static func replyPrompt(_ text: String, ctx context: CheckContext) -> String {
        """
        The user replied to you: "\(text)"
        Time: \(formatTime(context.now))
        Current state: \(context.state.rawValue)
        Active window: \(context.window.summary)

        User preferences (saved forever):
        \(formatPreferences(context.userPreferences))

        Current work hours: \(context.workHours.promptDescription)

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

    private static func formatPreferences(_ preferences: [String]) -> String {
        guard !preferences.isEmpty else { return "(none saved)" }
        return preferences.map { "- \($0)" }.joined(separator: "\n")
    }
}
