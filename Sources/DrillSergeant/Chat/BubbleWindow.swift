import AppKit
import QuartzCore
import SwiftUI

@MainActor
final class BubbleWindow: NSPanel, ChatPresenter {
    private static let width = BubbleStyle.width
    private static let initialHeight: CGFloat = 70
    private static let notchGap: CGFloat = 8
    private static let animationOffset: CGFloat = 6
    private static let animationDuration: TimeInterval = 0.2
    private static let autoHideSeconds: TimeInterval = 10

    private let notchGeometry: () -> NotchGeometry
    private let notchPanelHeight: CGFloat
    private let model: BubbleModel
    private let hostingView: BubbleHostingView<BubbleView>

    private var measuredHeight = BubbleWindow.initialHeight
    private var presentationOffset: CGFloat = 0
    private var autoHideEnabled = false
    private var autoHideTask: Task<Void, Never>?
    private var animationGeneration = 0

    var onVisibilityChange: ((Bool) -> Void)?
    /// Fired when the reply field opens or closes.
    var onInputStateChange: ((Bool) -> Void)?

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
        let hostingView = BubbleHostingView(rootView: view)

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
        // The window server draws this shadow from the content's alpha, outside the window
        // frame. A SwiftUI `.shadow()` gets clipped to its own layer bounds when AppKit
        // re-rasterizes the view, which happens a second or two after the window appears.
        hasShadow = true
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
        hostingView.clipsToBounds = false
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
        onInputStateChange?(isOpen)
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
        refreshShadow()
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
        refreshShadow()
    }

    /// The window shadow is cached from the content's alpha, so it has to be recomputed whenever
    /// the bubble changes shape. Otherwise a stale shadow outlines the previous size.
    private func refreshShadow() {
        guard isVisible else { return }
        invalidateShadow()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible else { return }
            self.invalidateShadow()
        }
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

        model.setCountdown(
            BubbleCountdown(start: Date(), duration: Self.autoHideSeconds)
        )
        autoHideTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(Self.autoHideSeconds * 1_000_000_000)
                )
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
        model.setCountdown(nil)
    }
}

/// Hosting view that claims the mouse cursor for the whole bubble.
///
/// The bubble panel is non-activating, so it is rarely the key window and AppKit leaves the
/// cursor to whatever window is underneath. Over a text area that means an I-beam. A
/// `.cursorUpdate` tracking area works regardless of key status and restores the arrow. The
/// reply field installs its own tracking area, so it still shows an I-beam when open.
@MainActor
final class BubbleHostingView<Content: View>: NSHostingView<Content> {
    private var cursorTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorTrackingArea {
            removeTrackingArea(cursorTrackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        cursorTrackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.arrow.set()
    }
}
