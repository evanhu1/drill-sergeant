import SwiftUI

@MainActor
final class BubbleModel: ObservableObject {
    @Published private(set) var text = ""
    @Published private(set) var isInputOpen = false
    @Published var replyText = ""
    @Published var isHovered = false

    var onReply: ((String) -> Void)?
    var onTap: (() -> Void)?
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
}

struct BubbleView: View {
    @ObservedObject var model: BubbleModel
    let onHeightChange: (CGFloat) -> Void

    @FocusState private var isReplyFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            BubbleTail()
                .fill(BubbleStyle.background)
                .frame(width: 18, height: 8)
                .overlay {
                    BubbleTailOutline()
                        .stroke(.white.opacity(0.1), lineWidth: 1)
                }

            content
        }
        .frame(width: BubbleStyle.width)
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !model.isInputOpen else { return }
            model.handleTap()
        }
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
        VStack(alignment: .leading, spacing: 8) {
            Text(model.text)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if model.isInputOpen {
                replyField
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                Text("reply ←")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .opacity(model.isHovered ? 1 : 0)
                    .frame(height: 18, alignment: .leading)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 13)
        .padding(.bottom, 12)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(BubbleStyle.background)
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(.white.opacity(0.1), lineWidth: 1)
                }
        }
        .animation(.easeInOut(duration: 0.2), value: model.isInputOpen)
    }

    private var replyField: some View {
        TextField("Talk back…", text: $model.replyText)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.white.opacity(0.08))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(.white.opacity(0.14), lineWidth: 1)
                    }
            }
            .focused($isReplyFocused)
            .onSubmit {
                model.submitReply()
            }
            .onAppear {
                isReplyFocused = true
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
    static let background = Color(
        red: 28 / 255,
        green: 28 / 255,
        blue: 30 / 255,
        opacity: 0.96
    )
}

private struct BubbleTail: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}

private struct BubbleTailOutline: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        }
    }
}

private struct BubbleHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
