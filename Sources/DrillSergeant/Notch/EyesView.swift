import SwiftUI

@MainActor
final class EyesModel: ObservableObject {
    @Published var state: CompanionState = .idle
    @Published var gaze: CGPoint = .zero
    @Published var isBlinking = false
}

@MainActor
struct EyesView: View {
    @ObservedObject var model: EyesModel
    var blinkProgress: CGFloat? = nil
    var gaze: CGPoint? = nil
    var animationsEnabled = true

    @State private var idleDrift = false
    @State private var shakeOffset: CGFloat = 0
    @State private var happyBounce: CGFloat = 0

    private let transitionAnimation = Animation.easeInOut(duration: 0.25)

    var body: some View {
        HStack(spacing: 12) {
            eye(.left)
            eye(.right)
        }
        .offset(
            x: gazeOffset.width + driftOffset.width + shakeOffset,
            y: gazeOffset.height + driftOffset.height + happyBounce
        )
        .animation(transitionAnimation, value: model.state)
        .animation(transitionAnimation, value: effectiveGaze)
        .task(id: model.state) {
            guard animationsEnabled else { return }
            await runBlinkLoopIfNeeded()
        }
        .task {
            guard animationsEnabled else { return }
            await runIdleDriftLoop()
        }
        .task(id: model.state) {
            guard animationsEnabled else { return }
            await runStateAccent()
        }
    }

    private enum EyeSide {
        case left
        case right
    }

    private func eye(_ side: EyeSide) -> some View {
        ZStack {
            standardEye(side)
                .opacity(model.state == .happy ? 0 : 1)
                .scaleEffect(
                    x: 1,
                    y: blinkScale,
                    anchor: .center
                )

            HappyEyeArc()
                .stroke(
                    .white,
                    style: StrokeStyle(
                        lineWidth: 3,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
                .frame(width: 15, height: 10)
                .opacity(model.state == .happy ? 1 : 0)
                .scaleEffect(model.state == .happy ? 1 : 0.75)
        }
        .frame(width: 16, height: 20)
    }

    private func standardEye(_ side: EyeSide) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(eyeColor)
                .frame(width: 14, height: eyeHeight)

            if model.state == .watching || model.state == .angry {
                Circle()
                    .fill(.black.opacity(model.state == .angry ? 0.34 : 0.23))
                    .frame(width: 3.5, height: 3.5)
            }

            if model.state == .angry {
                Rectangle()
                    .fill(.black)
                    .frame(width: 12, height: 5)
                    .rotationEffect(
                        .degrees(side == .left ? 20 : -20)
                    )
                    .offset(
                        x: side == .left ? 3 : -3,
                        y: -7
                    )
            }
        }
        .frame(width: 16, height: 20)
    }

    private var eyeColor: Color {
        model.state == .angry
            ? Color(red: 1, green: 90 / 255, blue: 90 / 255)
            : .white
    }

    private var eyeHeight: CGFloat {
        model.state == .watching ? 18 * 0.85 : 18
    }

    private var gazeOffset: CGSize {
        guard model.state == .watching || model.state == .angry else {
            return .zero
        }
        return CGSize(
            width: effectiveGaze.x * 4,
            height: -effectiveGaze.y * 4
        )
    }

    private var effectiveGaze: CGPoint {
        gaze ?? model.gaze
    }

    private var blinkScale: CGFloat {
        guard model.state == .idle else { return 1 }
        let progress = blinkProgress
            ?? (model.isBlinking ? 1 : 0)
        return 1 - min(max(progress, 0), 1) * 0.9
    }

    private var driftOffset: CGSize {
        guard animationsEnabled, model.state == .idle else { return .zero }
        return CGSize(
            width: idleDrift ? 0.8 : -0.8,
            height: idleDrift ? -0.35 : 0.35
        )
    }

    private func runBlinkLoopIfNeeded() async {
        guard model.state == .idle else {
            model.isBlinking = false
            return
        }

        while !Task.isCancelled, model.state == .idle {
            do {
                try await sleep(seconds: Double.random(in: 3 ... 6))
                guard !Task.isCancelled, model.state == .idle else { break }

                withAnimation(.easeInOut(duration: 0.06)) {
                    model.isBlinking = true
                }
                try await sleep(seconds: 0.12)
                withAnimation(.easeInOut(duration: 0.08)) {
                    model.isBlinking = false
                }
            } catch {
                model.isBlinking = false
                return
            }
        }
        model.isBlinking = false
    }

    private func runIdleDriftLoop() async {
        while !Task.isCancelled {
            withAnimation(.easeInOut(duration: 2.4)) {
                idleDrift.toggle()
            }
            do {
                try await sleep(seconds: 2.4)
            } catch {
                return
            }
        }
    }

    private func runStateAccent() async {
        withAnimation(transitionAnimation) {
            shakeOffset = 0
            happyBounce = 0
        }

        switch model.state {
        case .angry:
            await runAngryShakeLoop()
        case .happy:
            await runHappyBounce()
        case .idle, .watching:
            return
        }
    }

    private func runAngryShakeLoop() async {
        while !Task.isCancelled, model.state == .angry {
            do {
                try await sleep(seconds: Double.random(in: 1.8 ... 2.2))
                try await shake(to: -2)
                try await shake(to: 2)
                try await shake(to: 0)
            } catch {
                shakeOffset = 0
                return
            }
        }
    }

    private func shake(to offset: CGFloat) async throws {
        withAnimation(.easeInOut(duration: 0.055)) {
            shakeOffset = offset
        }
        try await sleep(seconds: 0.055)
    }

    private func runHappyBounce() async {
        do {
            withAnimation(.easeInOut(duration: 0.12)) {
                happyBounce = -2.5
            }
            try await sleep(seconds: 0.12)
            withAnimation(.easeInOut(duration: 0.1)) {
                happyBounce = 1
            }
            try await sleep(seconds: 0.1)
            withAnimation(.easeInOut(duration: 0.1)) {
                happyBounce = 0
            }
        } catch {
            happyBounce = 0
        }
    }

    private func sleep(seconds: Double) async throws {
        let nanoseconds = UInt64(seconds * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}

private struct HappyEyeArc: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY),
            control: CGPoint(x: rect.midX, y: rect.minY)
        )
        return path
    }
}
