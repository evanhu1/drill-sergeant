import AppKit
import QuartzCore
import SwiftUI

@MainActor
final class BubbleWindow: NSPanel, ChatPresenter {
    private static let width: CGFloat = 320 + 2 * 16
    private static let initialHeight: CGFloat = 70
    private static let notchGap: CGFloat = 8
    private static let animationOffset: CGFloat = 6
    private static let animationDuration: TimeInterval = 0.2
    private static let autoHideDelay: UInt64 = 20_000_000_000

    private let notchGeometry: () -> NotchGeometry
    private let notchPanelHeight: CGFloat
    private let model: BubbleModel
    private let hostingView: NSHostingView<BubbleView>

    private var measuredHeight = BubbleWindow.initialHeight
    private var presentationOffset: CGFloat = 0
    private var autoHideEnabled = false
    private var autoHideTask: Task<Void, Never>?
    private var animationGeneration = 0

    var onVisibilityChange: ((Bool) -> Void)?

    var onReply: ((String) -> Void)? {
        didSet { model.onReply = onReply }
    }

    var onTap: (() -> Void)? {
        didSet { model.onTap = onTap }
    }

    var isReplying: Bool { model.isInputOpen }

    override var canBecomeKey: Bool { true }

    init(
        notchGeometry: @escaping () -> NotchGeometry,
        panelHeight: CGFloat = 40
    ) {
        let model = BubbleModel()
        let view = BubbleView(model: model) { _ in }
        let hostingView = NSHostingView(rootView: view)

        self.notchGeometry = notchGeometry
        self.notchPanelHeight = panelHeight
        self.model = model
        self.hostingView = hostingView

        super.init(
            contentRect: CGRect(
                x: 0,
                y: 0,
                width: Self.width,
                height: Self.initialHeight
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        configurePanel()
        installContent()
        connectModel()
        positionPanel()
    }

    func show(_ text: String, autoHide: Bool) {
        model.replaceText(text)
        autoHideEnabled = autoHide
        presentIfNeeded()
        scheduleAutoHideIfNeeded()
    }

    func ask(_ text: String) {
        model.replaceText(text)
        autoHideEnabled = false
        cancelAutoHide()
        presentIfNeeded()
        model.openInput()
    }

    func hide() {
        cancelAutoHide()
        autoHideEnabled = false
        model.closeInput()

        guard isVisible else {
            alphaValue = 0
            orderOut(nil)
            return
        }

        animationGeneration += 1
        let generation = animationGeneration
        presentationOffset = Self.animationOffset

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().alphaValue = 0
            animator().setFrameOrigin(frameOrigin(offset: presentationOffset))
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.animationGeneration == generation else { return }
                self.orderOut(nil)
                self.presentationOffset = 0
                self.positionPanel()
                self.onVisibilityChange?(false)
            }
        }
    }

    private func configurePanel() {
        level = .statusBar
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
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
    }

    private func installContent() {
        hostingView.rootView = BubbleView(model: model) { [weak self] height in
            self?.updateHeight(height)
        }
        hostingView.frame = CGRect(
            origin: .zero,
            size: CGSize(width: Self.width, height: measuredHeight)
        )
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        contentView = hostingView
    }

    private func connectModel() {
        model.onClose = { [weak self] in
            self?.hide()
        }
        model.onInputStateChange = { [weak self] isOpen in
            self?.inputStateDidChange(isOpen)
        }
    }

    private func inputStateDidChange(_ isOpen: Bool) {
        if isOpen {
            cancelAutoHide()
            NSApp.activate(ignoringOtherApps: true)
            makeKeyAndOrderFront(nil)
        } else {
            resignKey()
            NSApp.deactivate()
            scheduleAutoHideIfNeeded()
        }
    }

    private func presentIfNeeded() {
        animationGeneration += 1
        let wasVisible = isVisible
        presentationOffset = 0
        positionPanel()
        guard !wasVisible else {
            alphaValue = 1
            return
        }

        presentationOffset = Self.animationOffset
        alphaValue = 0
        positionPanel()
        orderFrontRegardless()
        onVisibilityChange?(true)

        presentationOffset = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().alphaValue = 1
            animator().setFrameOrigin(frameOrigin(offset: 0))
        }
    }

    private func updateHeight(_ height: CGFloat) {
        guard height.isFinite, height > 0 else { return }
        let roundedHeight = ceil(height)
        guard abs(roundedHeight - measuredHeight) >= 0.5 else { return }
        measuredHeight = roundedHeight
        positionPanel()
    }

    private func positionPanel() {
        setFrame(
            CGRect(
                origin: frameOrigin(offset: presentationOffset),
                size: CGSize(width: Self.width, height: measuredHeight)
            ),
            display: isVisible
        )
    }

    private func frameOrigin(offset: CGFloat) -> CGPoint {
        let geometry = notchGeometry()
        let notchPanel = geometry.panelFrame(panelHeight: notchPanelHeight)
        let top = notchPanel.minY - Self.notchGap
        return CGPoint(
            x: notchPanel.midX - Self.width / 2,
            y: top - measuredHeight + offset
        )
    }

    private func scheduleAutoHideIfNeeded() {
        cancelAutoHide()
        guard autoHideEnabled, !model.isInputOpen, isVisible else { return }

        autoHideTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.autoHideDelay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    private func cancelAutoHide() {
        autoHideTask?.cancel()
        autoHideTask = nil
    }
}
