import AppKit
import SwiftUI

@MainActor
final class NotchWindow: NSPanel {
    private static let panelHeight: CGFloat = 34

    var onSetGoal: (() -> Void)?
    var onCheckNow: (() -> Void)?
    var onQuit: (() -> Void)?

    private let eyesModel: EyesModel
    private var detectedGeometry: NotchGeometry
    private let hostingView: NSHostingView<NotchPanelContent>

    var geometry: NotchGeometry { detectedGeometry }

    init(eyesModel: EyesModel) {
        let geometry = Self.detectGeometry()
        self.eyesModel = eyesModel
        self.detectedGeometry = geometry
        self.hostingView = NSHostingView(
            rootView: NotchPanelContent(
                model: eyesModel,
                notchHeight: geometry.notchRect.height,
                panelHeight: Self.panelHeight
            )
        )

        super.init(
            contentRect: geometry.panelFrame(panelHeight: Self.panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary,
            .ignoresCycle,
        ]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        ignoresMouseEvents = false
        isReleasedWhenClosed = false

        hostingView.frame = CGRect(origin: .zero, size: frame.size)
        hostingView.autoresizingMask = [.width, .height]
        contentView = hostingView

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func showOnScreen() {
        updateGeometry()
        orderFrontRegardless()
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .rightMouseDown:
            showContextMenu(for: event)
        case .leftMouseDown where event.modifierFlags.contains(.control):
            showContextMenu(for: event)
        case .leftMouseDown:
            break
        default:
            super.sendEvent(event)
        }
    }

    @objc private func screenParametersDidChange(_ notification: Notification) {
        updateGeometry()
    }

    private func updateGeometry() {
        detectedGeometry = Self.detectGeometry()
        let panelFrame = detectedGeometry.panelFrame(panelHeight: Self.panelHeight)
        setFrame(panelFrame, display: true)
        hostingView.rootView = NotchPanelContent(
            model: eyesModel,
            notchHeight: detectedGeometry.notchRect.height,
            panelHeight: Self.panelHeight
        )
    }

    private static func detectGeometry() -> NotchGeometry {
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            return NotchGeometry.detect(screen: screen)
        }

        return NotchGeometry.synthetic(
            screenFrame: CGRect(x: 0, y: 0, width: 200, height: 32)
        )
    }

    private func showContextMenu(for event: NSEvent) {
        guard let contentView else { return }
        NSMenu.popUpContextMenu(makeContextMenu(), with: event, for: contentView)
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(
            menuItem(title: "Set goal…", action: #selector(setGoal(_:)))
        )
        menu.addItem(
            menuItem(title: "Check now", action: #selector(checkNow(_:)))
        )
        menu.addItem(.separator())

        let quitItem = menuItem(
            title: "Quit Drill Sergeant",
            action: #selector(quit(_:))
        )
        quitItem.keyEquivalent = "q"
        quitItem.keyEquivalentModifierMask = [.command]
        menu.addItem(quitItem)
        return menu
    }

    private func menuItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func setGoal(_ sender: NSMenuItem) {
        onSetGoal?()
    }

    @objc private func checkNow(_ sender: NSMenuItem) {
        onCheckNow?()
    }

    @objc private func quit(_ sender: NSMenuItem) {
        onQuit?()
    }
}

private struct NotchPanelContent: View {
    @ObservedObject var model: EyesModel
    let notchHeight: CGFloat
    let panelHeight: CGFloat

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(.black)
                    .frame(height: notchHeight)
                UnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: 14,
                    bottomTrailingRadius: 14,
                    topTrailingRadius: 0,
                    style: .continuous
                )
                .fill(.black)
                .frame(height: panelHeight)
            }

            EyesView(model: model)
                .frame(height: panelHeight)
        }
    }
}
