// STUB: implemented in wave 2
import AppKit

@MainActor
final class BubbleWindow: NSPanel, ChatPresenter {
    var onReply: ((String) -> Void)?
    var onTap: (() -> Void)?

    override var canBecomeKey: Bool { true }

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
    }

    func show(_ text: String, autoHide: Bool) {}

    func ask(_ text: String) {}

    func hide() {}
}
