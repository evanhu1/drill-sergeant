import AppKit
import SwiftUI

enum GazeMapper {
    private static let power: CGFloat = 0.55

    /// 1 when the cursor is within `near` points of the face, fading to 0 by `far`.
    static func proximity(
        mouseLocation: CGPoint,
        panelCenter: CGPoint,
        near: CGFloat = 60,
        far: CGFloat = 360
    ) -> CGFloat {
        let distance = hypot(mouseLocation.x - panelCenter.x, mouseLocation.y - panelCenter.y)
        guard far > near else { return distance <= near ? 1 : 0 }
        return (1 - (distance - near) / (far - near)).clamped(to: 0 ... 1)
    }

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
            eyesModel.proximity = 0
        }
    }

    private func updateGaze() {
        guard let window = windowProvider(),
              let screenFrame = screenFrame(for: window),
              screenFrame.width > 0,
              screenFrame.height > 0 else {
            return
        }

        let mouseLocation = NSEvent.mouseLocation
        let panelCenter = CGPoint(x: window.frame.midX, y: window.frame.midY)
        let mappedGaze = GazeMapper.map(
            mouseLocation: mouseLocation,
            panelCenter: panelCenter,
            screenSize: screenFrame.size
        )
        let proximity = GazeMapper.proximity(
            mouseLocation: mouseLocation,
            panelCenter: panelCenter
        )
        withAnimation(.easeOut(duration: 0.12)) {
            eyesModel.gaze = mappedGaze
            eyesModel.proximity = proximity
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
