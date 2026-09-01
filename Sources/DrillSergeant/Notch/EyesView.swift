// STUB: implemented in wave 2
import SwiftUI

@MainActor
final class EyesModel: ObservableObject {
    @Published var state: CompanionState = .idle
    @Published var gaze: CGPoint = .zero
    @Published var isBlinking = false
}

struct EyesView: View {
    @ObservedObject var model: EyesModel

    var body: some View {
        Text("eyes")
    }
}
