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
        center()
    }

    override var canBecomeKey: Bool { true }

    func show() {
        orderFrontRegardless()
    }
}
