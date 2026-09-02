import AppKit
import SwiftUI

enum GazeMapper {
    private static let power: CGFloat = 0.55

    /// Maps screen-space cursor movement to normalized pupil travel.
    static func map(
        mouseLocation: CGPoint,
        panelCenter: CGPoint,
        screenSize: CGSize
    ) -> CGPoint {
        guard screenSize.width > 0, screenSize.height > 0 else { return .zero }

        let normalizedX = (mouseLocation.x - panelCenter.x) / (screenSize.width / 2)
        let normalizedY = (mouseLocation.y - panelCenter.y) / (screenSize.height / 2)
        return CGPoint(
            x: curved(normalizedX),
            y: -curved(normalizedY)
        )
    }

    private static func curved(_ value: CGFloat) -> CGFloat {
        let clamped = value.clamped(to: -1 ... 1)
        guard clamped != 0 else { return 0 }
        return clamped.sign == .minus
            ? -pow(abs(clamped), power)
            : pow(clamped, power)
    }
}

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

        let mappedGaze = GazeMapper.map(
            mouseLocation: NSEvent.mouseLocation,
            panelCenter: CGPoint(x: window.frame.midX, y: window.frame.midY),
            screenSize: screenFrame.size
        )
        withAnimation(.easeOut(duration: 0.12)) {
            eyesModel.gaze = mappedGaze
        }
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
