enum BubbleAffordance: Equatable {
    case reply
    case click
    case display

    var usesPointingHandCursor: Bool {
        self == .click
    }

    var actionHint: String? {
        switch self {
        case .reply: return "reply ←"
        case .click: return "Next →"
        case .display: return nil
        }
    }
}

@MainActor
protocol ChatPresenter: AnyObject {
    /// Show a message bubble under the notch.
    func show(_ text: String, autoHide: Bool)

    /// Show a message that expects a reply. The bubble stays up until it is answered or closed;
    /// the reply field opens only when the user clicks the bubble.
    func ask(_ text: String)

    func hide()

    /// Called when the user submits a reply.
    var onReply: ((String) -> Void)? { get set }
    /// Called when the user clicks a `.click` bubble's body.
    var onTap: (() -> Void)? { get set }
    /// Overrides the close button's normal hide behavior while set.
    var onClose: (() -> Void)? { get set }
    /// Controls the quiet action label in the bubble's bottom-right margin.
    var affordance: BubbleAffordance { get set }
}
