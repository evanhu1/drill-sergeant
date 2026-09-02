import AppKit
import SwiftUI

@MainActor
final class DevToolbar: NSPanel {
    init(actions: DevActions) {
        let content = DevToolbarView(actions: actions)
        let hostingView = NSHostingView(rootView: content)

        super.init(
            contentRect: CGRect(x: 0, y: 0, width: 360, height: 860),
            styleMask: [.utilityWindow, .titled, .closable],
            backing: .buffered,
            defer: false
        )

        title = "Drill Sergeant Developer"
        level = .floating
        isFloatingPanel = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentMinSize = CGSize(width: 360, height: 500)
        contentMaxSize = CGSize(width: 360, height: 1200)
        contentView = hostingView
        center()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        orderFrontRegardless()
        makeKey()
    }
}
