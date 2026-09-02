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
    /// Called when the user clicks the bubble body.
    var onTap: (() -> Void)? { get set }
}
