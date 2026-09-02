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
    var angryProgress: CGFloat? = nil
    var smileProgress: CGFloat? = nil

    @State private var happyScale: CGFloat = 1
    @State private var isGlancing = false

    /// Wider than tall, so the eye reads almond rather than egg.
    private let scleraSize = CGSize(width: 24, height: 23)
    /// A cat's vertical slit. Narrow enough to travel sideways, tall enough that it barely can
    /// travel up or down, which is what `pupilTravel` accounts for.
    private let pupilSize = CGSize(width: 7, height: 15)
    private let pupilTravel = CGSize(width: 6, height: 5)
    /// Thickness of the smile arc at its middle, and how far it sits below the open eye's centre.
    private let smileArc: CGFloat = 6
    private let smileDrop: CGFloat = 7

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
        standardEye(side)
            .scaleEffect(happyScale)
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
                    x: lookGaze.x * pupilTravel.width + convergence(for: side),
                    y: lookGaze.y * pupilTravel.height
                )
                // A pupil left showing inside the smile arc reads as a stare, not a smile.
                .opacity(pupilOpacity)
        }
        .frame(width: scleraSize.width, height: scleraSize.height)
        .clipShape(Ellipse())
        .clipShape(lidClip(for: side))
        .clipShape(EyelidClip(progress: eyelidProgress))
        .clipShape(SmileCrescent(shift: smileShift), style: FillStyle(eoFill: true))
        .offset(y: smileAmount * smileDrop)
        .scaleEffect(scleraScale)
    }

    private func lidClip(for side: EyeSide) -> AngryLidClip {
        AngryLidClip(
            side: side == .left ? .left : .right,
            progress: angryProgress ?? (model.state == .angry ? 1 : 0)
        )
    }

    /// How far the eye has closed into its smile arc.
    private var smileAmount: CGFloat {
        (smileProgress ?? (model.state == .happy ? 1 : 0)).clamped(to: 0 ... 1)
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

    /// Final pupil direction, after a glance at the bubble takes over from the cursor.
    private var lookGaze: CGPoint {
        if glancingAtBubble {
            return CGPoint(x: 0, y: 0.95)
        }
        return baseGaze
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

    /// The cutter starts a whole eye-height below, where it removes nothing, and rises until only
    /// `smileArc` points of eye are left.
    private var smileShift: CGFloat {
        scleraSize.height - (scleraSize.height - smileArc) * smileAmount
    }

    private var pupilOpacity: CGFloat {
        max(0, 1 - smileAmount * 1.6)
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

    /// A cool off-white rather than a warm cream: warmth reads friendly.
    private var cream: Color {
        Color(red: 232 / 255, green: 234 / 255, blue: 238 / 255)
    }

    private var iris: Color {
        Color(red: 62 / 255, green: 74 / 255, blue: 96 / 255)
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

/// Cuts the eye with a copy of its own ellipse sitting below it, leaving a crescent whose outer
/// edge is the eye's own silhouette. The smile is therefore the same eye, not a second shape.
///
/// The cutter is used as a hole in a large rectangle rather than as a second ellipse in an
/// even-odd pair: an even-odd pair leaves a filled region below the eye whose edge coincides with
/// the eye's own, and the two anti-aliased edges leave a pale seam along the bottom.
private struct SmileCrescent: Shape {
    var shift: CGFloat

    var animatableData: CGFloat {
        get { shift }
        set { shift = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path(rect.insetBy(dx: -rect.width, dy: -rect.height))
        path.addPath(Path(ellipseIn: rect.offsetBy(dx: 0, dy: shift)))
        return path
    }
}
