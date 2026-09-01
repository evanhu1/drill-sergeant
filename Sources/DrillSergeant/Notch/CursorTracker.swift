import AppKit
import SwiftUI

@MainActor
final class CursorTracker {
    private let eyesModel: EyesModel
    private let windowProvider: () -> NSWindow?
    private var pollingTask: Task<Void, Never>?

    init(eyesModel: EyesModel, windowProvider: @escaping () -> NSWindow?) {
        self.eyesModel = eyesModel
        self.windowProvider = windowProvider
    }

    deinit {
        pollingTask?.cancel()
    }

    func start() {
        guard pollingTask == nil else { return }

        pollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.updateGaze()
                do {
                    try await Task.sleep(nanoseconds: 33_333_333)
                } catch {
                    return
                }
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        withAnimation(.easeInOut(duration: 0.25)) {
            eyesModel.gaze = .zero
        }
    }

    private func updateGaze() {
        guard let window = windowProvider(),
              let screenFrame = screenFrame(for: window),
              screenFrame.width > 0,
              screenFrame.height > 0 else {
            return
        }

        let mouse = NSEvent.mouseLocation
        let panelCenter = CGPoint(x: window.frame.midX, y: window.frame.midY)
        let normalizedX = (mouse.x - panelCenter.x) / (screenFrame.width / 2)
        let normalizedY = (mouse.y - panelCenter.y) / (screenFrame.height / 2)
        eyesModel.gaze = CGPoint(
            x: normalizedX.clamped(to: -1 ... 1),
            y: normalizedY.clamped(to: -1 ... 1)
        )
    }

    private func screenFrame(for window: NSWindow) -> CGRect? {
        if let screen = window.screen {
            return screen.frame
        }
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(window.frame) }) {
            return screen.frame
        }
        return NSScreen.main?.frame
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
