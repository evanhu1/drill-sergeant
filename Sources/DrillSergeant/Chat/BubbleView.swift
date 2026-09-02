import SwiftUI

@MainActor
final class BubbleModel: ObservableObject {
    @Published private(set) var text = ""
    @Published private(set) var isInputOpen = false
    @Published var replyText = ""
    @Published var isHovered = false

    var onReply: ((String) -> Void)?
    var onTap: (() -> Void)?
    var onClose: (() -> Void)?
    var onInputStateChange: ((Bool) -> Void)?

    func replaceText(_ text: String) {
        self.text = text
    }

    func handleTap() {
        if let onTap {
            onTap()
        } else {
            openInput()
        }
    }

    func openInput() {
        guard !isInputOpen else { return }
        isInputOpen = true
        onInputStateChange?(true)
    }

    func closeInput() {
        guard isInputOpen else { return }
        replyText = ""
        isInputOpen = false
        onInputStateChange?(false)
    }

    func submitReply() {
        let reply = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else { return }
        closeInput()
        onReply?(reply)
    }

    func requestClose() {
        closeInput()
        onClose?()
    }
}

struct BubbleView: View {
    @ObservedObject var model: BubbleModel
    let onHeightChange: (CGFloat) -> Void
    var staticHover: Bool? = nil
    var autoFocusInput = true
    var staticReplyText: String? = nil

    @FocusState private var isReplyFocused: Bool
    @State private var isCloseHovered = false

    init(
        model: BubbleModel,
        staticHover: Bool? = nil,
        autoFocusInput: Bool = true,
        staticReplyText: String? = nil,
        onHeightChange: @escaping (CGFloat) -> Void
    ) {
        self.model = model
        self.staticHover = staticHover
        self.autoFocusInput = autoFocusInput
        self.staticReplyText = staticReplyText
        self.onHeightChange = onHeightChange
    }

    var body: some View {
        VStack(spacing: 0) {
            BubbleTail()
                .fill(BubbleStyle.surface)
                .frame(width: BubbleStyle.tailWidth, height: BubbleStyle.tailHeight)
                .offset(y: 1) // overlap the body so no seam shows
                .contentShape(Rectangle())
                .onTapGesture(perform: handleBubbleTap)

            content
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.22), radius: 9, y: 4)
        .shadow(color: .black.opacity(0.10), radius: 1.5, y: 1)
        .frame(width: BubbleStyle.width)
        .padding(.horizontal, BubbleStyle.outerPadding)
        .padding(.bottom, BubbleStyle.outerPadding + 4)
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                model.isHovered = hovering
            }
        }
        .onExitCommand {
            model.closeInput()
        }
        .background(heightReader)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.text)
                .font(BubbleStyle.bodyFont)
                .foregroundStyle(BubbleStyle.ink)
                .lineSpacing(2)
                .lineLimit(10)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 18)

            if model.isInputOpen {
                replyField
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, model.isInputOpen ? 12 : BubbleStyle.hintGutter)
        .background {
            RoundedRectangle(cornerRadius: BubbleStyle.cornerRadius, style: .continuous)
                .fill(BubbleStyle.surface)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: handleBubbleTap)
        .overlay(alignment: .topTrailing) {
            closeButton
                .padding(9)
        }
        .overlay(alignment: .bottomTrailing) {
            replyHint
        }
        .animation(.easeInOut(duration: 0.2), value: model.isInputOpen)
    }

    /// Sits in the bubble's bottom margin, right side. It never affects layout.
    private var replyHint: some View {
        Text("reply ←")
            .font(BubbleStyle.hintFont)
            .foregroundStyle(BubbleStyle.muted)
            .padding(.trailing, 16)
            .padding(.bottom, 5)
            .opacity(showsReplyHint ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var showsReplyHint: Bool {
        guard !model.isInputOpen else { return false }
        return staticHover ?? model.isHovered
    }

    private var closeButton: some View {
        Button {
            model.requestClose()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(isCloseHovered ? BubbleStyle.ink : BubbleStyle.muted)
                .frame(width: 18, height: 18)
                .background {
                    Circle()
                        .fill(isCloseHovered ? BubbleStyle.fieldHover : BubbleStyle.field)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isCloseHovered = hovering
            }
        }
        .accessibilityLabel("Close")
    }

    private func handleBubbleTap() {
        guard !model.isInputOpen else { return }
        model.handleTap()
    }

    @ViewBuilder
    private var replyField: some View {
        Group {
            if let staticReplyText {
                Text(staticReplyText.isEmpty ? "Talk back…" : staticReplyText)
                    .foregroundStyle(staticReplyText.isEmpty ? BubbleStyle.muted : BubbleStyle.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField(
                    "",
                    text: $model.replyText,
                    prompt: Text("Talk back…").foregroundColor(BubbleStyle.muted)
                )
                    .textFieldStyle(.plain)
                    .foregroundStyle(BubbleStyle.ink)
                    .focused($isReplyFocused)
                    .onSubmit {
                        model.submitReply()
                    }
                    .onAppear {
                        if autoFocusInput {
                            isReplyFocused = true
                        }
                    }
            }
        }
            .font(BubbleStyle.bodyFont)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(BubbleStyle.field)
            }
    }

    private var heightReader: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: BubbleHeightPreferenceKey.self,
                value: proxy.size.height
            )
        }
        .onPreferenceChange(BubbleHeightPreferenceKey.self, perform: onHeightChange)
    }
}

private enum BubbleStyle {
    static let width: CGFloat = 320
    /// Room around the bubble for its shadow; the window is this much wider on each side.
    static let outerPadding: CGFloat = 16
    static let cornerRadius: CGFloat = 20
    /// Bottom margin kept clear for the reply hint when the input is closed.
    static let hintGutter: CGFloat = 22
    static let tailWidth: CGFloat = 26
    static let tailHeight: CGFloat = 12

    /// Warm white, same family as the eyes' sclera so the bubble reads as the character speaking.
    static let surface = Color(red: 1.0, green: 0.992, blue: 0.98)
    static let ink = Color(red: 0.11, green: 0.10, blue: 0.11)
    static let muted = Color(red: 0.55, green: 0.53, blue: 0.55)
    static let field = Color(red: 0.94, green: 0.925, blue: 0.91)
    static let fieldHover = Color(red: 0.89, green: 0.87, blue: 0.855)

    static let bodyFont = Font.system(size: 14, weight: .medium, design: .rounded)
    static let hintFont = Font.system(size: 11, weight: .medium, design: .rounded)
}

/// A comic-style tail pointing up at the notch: slightly curved sides, rounded tip.
private struct BubbleTail: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            let tip = CGPoint(x: rect.midX, y: rect.minY)
            let left = CGPoint(x: rect.minX, y: rect.maxY)
            let right = CGPoint(x: rect.maxX, y: rect.maxY)
            path.move(to: left)
            path.addQuadCurve(
                to: tip,
                control: CGPoint(x: rect.midX - rect.width * 0.18, y: rect.minY + rect.height * 0.55)
            )
            path.addQuadCurve(
                to: right,
                control: CGPoint(x: rect.midX + rect.width * 0.18, y: rect.minY + rect.height * 0.55)
            )
            path.closeSubpath()
        }
    }
}

private struct BubbleHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
