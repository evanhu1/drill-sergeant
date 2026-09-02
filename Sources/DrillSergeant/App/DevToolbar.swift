import AppKit
import SwiftUI

@MainActor
final class DevToolbar: NSPanel {
    init(actions: DevActions) {
        let content = DevToolbarView(actions: actions)
        let hostingView = NSHostingView(rootView: content)

        super.init(
            contentRect: CGRect(x: 0, y: 0, width: 360, height: 860),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        title = "Drill Sergeant Developer"
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentMinSize = CGSize(width: 360, height: 500)
        contentMaxSize = CGSize(width: 360, height: 1200)
        contentView = hostingView
        level = .floating
        placeInTopRightCorner()
    }

    override var canBecomeKey: Bool { true }

    /// Keeps the toolbar out from under the notch and the bubble.
    private func placeInTopRightCorner() {
        guard let screen = NSScreen.main else { center(); return }
        let visible = screen.visibleFrame
        let margin: CGFloat = 20
        setFrameOrigin(CGPoint(
            x: visible.maxX - frame.width - margin,
            y: visible.maxY - frame.height - margin
        ))
    }

    func show() {
        orderFrontRegardless()
    }
}
