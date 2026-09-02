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

    @State private var happyScale: CGFloat = 1

    private let scleraSize = CGSize(width: 22, height: 27)
    private let pupilSize = CGSize(width: 11, height: 13)
    private let transitionAnimation = Animation.easeInOut(duration: 0.25)

    var body: some View {
        HStack(spacing: 5) {
            eye(.left)
            eye(.right)
        }
        .padding(.bottom, 4)
        .animation(transitionAnimation, value: model.state)
        .animation(.easeOut(duration: 0.12), value: effectiveGaze)
        .task(id: model.state) {
            guard animationsEnabled else { return }
            await runBlinkLoopIfNeeded()
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
                .rotationEffect(.degrees(side == .left ? -8 : 8))
                .scaleEffect(x: 1, y: model.state == .happy ? 0.08 : 1)
                .opacity(model.state == .happy ? 0 : 1)

            HappyEyeArc()
                .stroke(
                    cream,
                    style: StrokeStyle(
                        lineWidth: 3.5,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
                .frame(width: scleraSize.width, height: 14)
                .scaleEffect((model.state == .happy ? 1 : 0.75) * happyScale)
                .opacity(model.state == .happy ? 1 : 0)
        }
        .frame(width: scleraSize.width, height: scleraSize.height)
    }

    private func standardEye(_ side: EyeSide) -> some View {
        ZStack {
            Ellipse()
                .fill(cream)

            Ellipse()
                .fill(iris)
                .frame(
                    width: pupilSize.width * pupilScale,
                    height: pupilSize.height * pupilScale
                )
                .offset(
                    x: effectiveGaze.x * 5,
                    y: 1 + effectiveGaze.y * 6
                )
        }
        .frame(width: scleraSize.width, height: scleraSize.height)
        .clipShape(Ellipse())
        .clipShape(lidClip(for: side))
        .clipShape(EyelidClip(progress: blinkAmount))
        .scaleEffect(scleraScale)
    }

    private func lidClip(for side: EyeSide) -> AngryLidClip {
        AngryLidClip(
            side: side == .left ? .left : .right,
            progress: model.state == .angry ? 1 : 0
        )
    }

    private var effectiveGaze: CGPoint {
        let value = gaze ?? model.gaze
        return CGPoint(
            x: value.x.clamped(to: -1 ... 1),
            y: value.y.clamped(to: -1 ... 1)
        )
    }

    private var scleraScale: CGFloat {
        model.state == .watching ? 1.08 : 1
    }

    private var pupilScale: CGFloat {
        switch model.state {
        case .watching:
            return 0.85
        case .angry:
            return 0.9
        case .idle, .happy:
            return 1
        }
    }

    private var blinkAmount: CGFloat {
        (blinkProgress ?? (model.isBlinking ? 1 : 0)).clamped(to: 0 ... 1)
    }

    private var cream: Color {
        Color(red: 251 / 255, green: 238 / 255, blue: 227 / 255)
    }

    private var iris: Color {
        Color(red: 107 / 255, green: 120 / 255, blue: 230 / 255)
    }

    private func runBlinkLoopIfNeeded() async {
        guard model.state == .idle || model.state == .watching else {
            model.isBlinking = false
            return
        }

        while !Task.isCancelled,
              (model.state == .idle || model.state == .watching)
        {
            do {
                try await sleep(seconds: blinkDelay)
                guard !Task.isCancelled,
                      (model.state == .idle || model.state == .watching)
                else { break }

                withAnimation(.easeIn(duration: 0.07)) {
                    model.isBlinking = true
                }
                try await sleep(seconds: 0.1)
                withAnimation(.easeOut(duration: 0.13)) {
                    model.isBlinking = false
                }
            } catch {
                model.isBlinking = false
                return
            }
        }
        model.isBlinking = false
    }

    private var blinkDelay: Double {
        model.state == .watching
            ? Double.random(in: 6 ... 10)
            : Double.random(in: 3 ... 6)
    }

    private func runStateAccent() async {
        happyScale = 1

        switch model.state {
        case .happy:
            await runHappyBounce()
        case .idle, .watching, .angry:
            return
        }
    }

    private func runHappyBounce() async {
        happyScale = 1.15
        await Task.yield()
        do {
            withAnimation(.easeInOut(duration: 0.3)) {
                happyScale = 1
            }
            try await sleep(seconds: 0.3)
        } catch {
            happyScale = 1
        }
    }

    private func sleep(seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

private struct AngryLidClip: Shape {
    enum Side {
        case left
        case right
    }

    let side: Side
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let leftTopFraction: CGFloat = side == .left ? 0.22 : 0.52
        let rightTopFraction: CGFloat = side == .left ? 0.52 : 0.22
        var path = Path()
        path.move(
            to: CGPoint(
                x: rect.minX,
                y: rect.minY + rect.height * leftTopFraction * progress
            )
        )
        path.addLine(
            to: CGPoint(
                x: rect.maxX,
                y: rect.minY + rect.height * rightTopFraction * progress
            )
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct HappyEyeArc: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY * 0.82))
        path.addCurve(
            to: CGPoint(x: rect.midX, y: rect.minY),
            control1: CGPoint(x: rect.minX + rect.width * 0.18, y: rect.height * 0.42),
            control2: CGPoint(x: rect.midX - rect.width * 0.18, y: rect.minY)
        )
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY * 0.82),
            control1: CGPoint(x: rect.midX + rect.width * 0.18, y: rect.minY),
            control2: CGPoint(x: rect.maxX - rect.width * 0.18, y: rect.height * 0.42)
        )
        return path
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

/// An eyelid closing from the top. The lid's edge is a curve that dips in the middle, so the eye
/// shuts the way a lid does rather than collapsing into a straight slit.
private struct EyelidClip: Shape {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        guard progress > 0 else { return Path(rect) }

        let bow = rect.height * 0.13
        // Travel far enough that the bowed edge clears the bottom of the eye when fully closed.
        let edgeY = rect.minY - bow + (rect.height + bow) * min(progress, 1)

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: edgeY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: edgeY),
            control: CGPoint(x: rect.midX, y: edgeY + 2 * bow)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
