// STUB: implemented in wave 2
@MainActor
protocol ChatPresenter: AnyObject {
    /// Shows a bubble and optionally hides it after the idle timeout.
    func show(_ text: String, autoHide: Bool)

    /// Shows a message and immediately opens its reply field.
    func ask(_ text: String)

    func hide()

    var onReply: ((String) -> Void)? { get set }
    var onTap: (() -> Void)? { get set }
}
