import SwiftUI

/// What the eyes are paying attention to. The cursor is the default; the coordinator switches
/// to `.bubble` when a message appears and `.typing` while the reply field is open.
enum EyeAttention: Equatable {
    case cursor
    case bubble
    case typing
}

@MainActor
final class EyesModel: ObservableObject {
    @Published var state: CompanionState = .idle
    @Published var gaze: CGPoint = .zero
    @Published var isBlinking = false
    /// 1 when the cursor is right at the face, 0 when it is far away. Drives convergence.
    @Published var proximity: CGFloat = 0
    @Published var attention: EyeAttention = .cursor
}

@MainActor
struct EyesView: View {
    @ObservedObject var model: EyesModel
    var blinkProgress: CGFloat? = nil
    var gaze: CGPoint? = nil
    var animationsEnabled = true
    /// Static inputs for renders. When set they replace the live, timed behaviour.
    var proximity: CGFloat? = nil
    var attention: EyeAttention? = nil

    @State private var happyScale: CGFloat = 1
    @State private var saccade: CGPoint = .zero
    @State private var isGlancing = false

    private let scleraSize = CGSize(width: 22, height: 27)
    private let pupilSize = CGSize(width: 11, height: 13)

    var body: some View {
        HStack(spacing: 5) {
            eye(.left)
            eye(.right)
        }
        .padding(.bottom, 4)
        // Whole-face motion: the pair turns and leans toward the cursor.
        .rotationEffect(.degrees(headTilt))
        .offset(x: lean.x, y: lean.y)
        .task(id: model.state) {
            guard animationsEnabled else { return }
            await runBlinkLoopIfNeeded()
        }
        .task(id: model.state) {
            guard animationsEnabled else { return }
            await runStateAccent()
        }
        .task(id: model.state) {
            guard animationsEnabled else { return }
            await runSaccadesIfNeeded()
        }
        .task(id: model.attention) {
            guard animationsEnabled else { return }
            await runGlance()
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
                    x: lookGaze.x * 5 + convergence(for: side),
                    y: 1 + lookGaze.y * 6
                )
        }
        .frame(width: scleraSize.width, height: scleraSize.height)
        .clipShape(Ellipse())
        .clipShape(lidClip(for: side))
        .clipShape(EyelidClip(progress: eyelidProgress))
        .scaleEffect(scleraScale)
    }

    private func lidClip(for side: EyeSide) -> AngryLidClip {
        AngryLidClip(
            side: side == .left ? .left : .right,
            progress: model.state == .angry ? 1 : 0
        )
    }

    // MARK: - Where the eyes look

    /// Cursor-driven gaze, before any layered behaviour.
    private var baseGaze: CGPoint {
        let value = gaze ?? model.gaze
        return CGPoint(
            x: value.x.clamped(to: -1 ... 1),
            y: value.y.clamped(to: -1 ... 1)
        )
    }

    /// Final pupil direction after the glance and saccade are layered on.
    private var lookGaze: CGPoint {
        if glancingAtBubble {
            return CGPoint(x: 0, y: 0.95)
        }
        return CGPoint(
            x: (baseGaze.x + saccade.x).clamped(to: -1 ... 1),
            y: (baseGaze.y + saccade.y).clamped(to: -1 ... 1)
        )
    }

    private var glancingAtBubble: Bool {
        if let attention {
            return attention != .cursor
        }
        return isGlancing
    }

    private var effectiveProximity: CGFloat {
        (proximity ?? model.proximity).clamped(to: 0 ... 1)
    }

    /// Pupils turn inward as the cursor gets close to the face.
    private func convergence(for side: EyeSide) -> CGFloat {
        let inward: CGFloat = 1.6 * effectiveProximity
        return side == .left ? inward : -inward
    }

    private var headTilt: Double {
        Double(baseGaze.x) * 4
    }

    private var lean: CGPoint {
        CGPoint(x: baseGaze.x * 2, y: baseGaze.y * 1.5)
    }

    // MARK: - Lids

    private var blinkAmount: CGFloat {
        (blinkProgress ?? (model.isBlinking ? 1 : 0)).clamped(to: 0 ... 1)
    }

    private var eyelidProgress: CGFloat {
        blinkAmount
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

    private var cream: Color {
        Color(red: 251 / 255, green: 238 / 255, blue: 227 / 255)
    }

    private var iris: Color {
        Color(red: 107 / 255, green: 120 / 255, blue: 230 / 255)
    }

    // MARK: - Timed behaviour

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

    /// Small, quick flicks of the pupils while idle, so tracking never looks mechanical.
    private func runSaccadesIfNeeded() async {
        saccade = .zero
        guard model.state == .idle else { return }

        while !Task.isCancelled, model.state == .idle {
            do {
                try await sleep(seconds: Double.random(in: 2 ... 5))
                guard !Task.isCancelled, model.state == .idle, !isGlancing else { continue }

                withAnimation(.easeOut(duration: 0.06)) {
                    saccade = CGPoint(
                        x: CGFloat.random(in: -0.35 ... 0.35),
                        y: CGFloat.random(in: -0.2 ... 0.2)
                    )
                }
                try await sleep(seconds: Double.random(in: 0.12 ... 0.2))
                withAnimation(.easeOut(duration: 0.08)) {
                    saccade = .zero
                }
            } catch {
                saccade = .zero
                return
            }
        }
        saccade = .zero
    }

    /// A new message pulls the eyes down to the bubble briefly. Typing holds them there.
    private func runGlance() async {
        switch model.attention {
        case .cursor:
            withAnimation(.easeOut(duration: 0.2)) {
                isGlancing = false
            }
        case .typing:
            withAnimation(.easeOut(duration: 0.15)) {
                isGlancing = true
            }
        case .bubble:
            withAnimation(.easeOut(duration: 0.15)) {
                isGlancing = true
            }
            try? await sleep(seconds: 0.7)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                isGlancing = false
            }
        }
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
