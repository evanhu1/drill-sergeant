import AppKit
import Combine
import SwiftUI

@MainActor
final class NotchWindow: NSPanel {
    private static let panelHeight: CGFloat = 40

    var onSetGoal: (() -> Void)?
    var onCheckNow: (() -> Void)?
    var onDeveloper: (() -> Void)?
    var onQuit: (() -> Void)?

    private let eyesModel: EyesModel
    private var detectedGeometry: NotchGeometry
    private let trayController: TrayController
    private let presentationModel: NotchPresentationModel
    private let hostingView: HoverTrackingHostingView<NotchPanelHost>
    private var stateCancellable: AnyCancellable?

    var geometry: NotchGeometry { detectedGeometry }

    init(eyesModel: EyesModel) {
        let geometry = Self.detectGeometry()
        let presentationModel = NotchPresentationModel(
            notchHeight: geometry.notchRect.height,
            panelHeight: Self.panelHeight
        )
        let trayController = TrayController(
            clock: SystemClock(),
            state: eyesModel.state
        )
        self.eyesModel = eyesModel
        self.detectedGeometry = geometry
        self.trayController = trayController
        self.presentationModel = presentationModel
        self.hostingView = HoverTrackingHostingView(
            rootView: NotchPanelHost(
                eyesModel: eyesModel,
                presentationModel: presentationModel
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

        trayController.onExtensionChange = { [weak self] extended in
            self?.setTrayOffset(extended: extended, animated: true)
        }
        hostingView.onHoverChange = { [weak trayController] hovering in
            trayController?.setHovering(hovering)
        }
        stateCancellable = eyesModel.$state.sink { [weak trayController] state in
            trayController?.setState(state)
        }

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

    func setTrayPinned(_ pinned: Bool) {
        trayController.setPinned(pinned)
    }

    func setTrayExtended(_ extended: Bool, animated: Bool = true) {
        setTrayOffset(extended: extended, animated: animated)
        trayController.setExtended(extended)
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
        presentationModel.notchHeight = detectedGeometry.notchRect.height
    }

    private func setTrayOffset(extended: Bool, animated: Bool) {
        let offset = extended ? 0 : Self.panelHeight
        guard presentationModel.trayOffset != offset else { return }

        if animated {
            withAnimation(.easeInOut(duration: 0.3)) {
                presentationModel.trayOffset = offset
            }
        } else {
            presentationModel.trayOffset = offset
        }
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
        menu.addItem(
            menuItem(title: "Developer…", action: #selector(showDeveloper(_:)))
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

    @objc private func showDeveloper(_ sender: NSMenuItem) {
        onDeveloper?()
    }

    @objc private func quit(_ sender: NSMenuItem) {
        onQuit?()
    }
}

@MainActor
private final class NotchPresentationModel: ObservableObject {
    @Published var notchHeight: CGFloat
    @Published var trayOffset: CGFloat = 0
    let panelHeight: CGFloat

    init(notchHeight: CGFloat, panelHeight: CGFloat) {
        self.notchHeight = notchHeight
        self.panelHeight = panelHeight
    }
}

@MainActor
private struct NotchPanelHost: View {
    @ObservedObject var eyesModel: EyesModel
    @ObservedObject var presentationModel: NotchPresentationModel

    var body: some View {
        NotchPanelContent(
            model: eyesModel,
            notchHeight: presentationModel.notchHeight,
            panelHeight: presentationModel.panelHeight,
            trayOffset: presentationModel.trayOffset
        )
    }
}

@MainActor
struct NotchPanelContent: View {
    @ObservedObject var model: EyesModel
    let notchHeight: CGFloat
    let panelHeight: CGFloat
    /// 0 = tray extended, `panelHeight` = tray hidden inside the notch.
    var trayOffset: CGFloat = 0
    var blinkProgress: CGFloat? = nil
    var gaze: CGPoint? = nil
    var animationsEnabled = true

    var body: some View {
        ZStack(alignment: .top) {
            ZStack(alignment: .bottom) {
                UnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: 14,
                    bottomTrailingRadius: 14,
                    topTrailingRadius: 0,
                    style: .continuous
                )
                .fill(.black)
                .frame(height: panelHeight)

                EyesView(
                    model: model,
                    blinkProgress: blinkProgress,
                    gaze: gaze,
                    animationsEnabled: animationsEnabled
                )
                .frame(height: panelHeight)
            }
            .frame(height: panelHeight)
            .offset(y: notchHeight - trayOffset)

            Rectangle()
                .fill(.black)
                .frame(height: notchHeight)
        }
        .frame(height: notchHeight + panelHeight, alignment: .top)
        .clipped()
    }
}

@MainActor
private final class HoverTrackingHostingView<Content: View>: NSHostingView<Content> {
    var onHoverChange: ((Bool) -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let newTrackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(newTrackingArea)
        hoverTrackingArea = newTrackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChange?(false)
    }
}
