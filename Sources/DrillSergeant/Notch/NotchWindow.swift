// STUB: implemented in wave 2
import AppKit

@MainActor
final class NotchWindow: NSPanel {
    var onSetGoal: (() -> Void)?
    var onCheckNow: (() -> Void)?
    var onQuit: (() -> Void)?

    init(model: EyesModel) {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
    }
}
