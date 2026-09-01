// STUB: implemented in wave 2
import AppKit

@MainActor
final class CursorTracker {
    private let eyesModel: EyesModel
    private let windowProvider: () -> NSWindow?

    init(eyesModel: EyesModel, windowProvider: @escaping () -> NSWindow?) {
        self.eyesModel = eyesModel
        self.windowProvider = windowProvider
    }

    func start() {
        _ = windowProvider()
    }

    func stop() {
        eyesModel.gaze = .zero
    }
}
