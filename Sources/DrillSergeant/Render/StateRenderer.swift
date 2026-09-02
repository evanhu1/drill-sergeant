import AppKit
import SwiftUI

@MainActor
enum StateRenderer {
    nonisolated static var defaultOutputURL: URL {
        URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        .appendingPathComponent("build/renders", isDirectory: true)
    }

    private static let notchSize = CGSize(width: 200, height: 72)
    private static let bubbleSize = CGSize(width: 320, height: 112)
    private static let bubbleInputSize = CGSize(width: 320, height: 122)
    private static let background = Color(
        red: 128 / 255,
        green: 128 / 255,
        blue: 128 / 255
    )

    /// Renders deterministic snapshots of every companion state without creating windows.
    static func render(to outputURL: URL = defaultOutputURL) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: outputURL,
            withIntermediateDirectories: true
        )

        var rendered: [(name: String, image: NSImage)] = []
        try renderNotch(
            name: "idle.png",
            state: .idle,
            blinkProgress: 0,
            outputURL: outputURL,
            rendered: &rendered
        )
        try renderNotch(
            name: "idle-blink.png",
            state: .idle,
            blinkProgress: 0.5,
            outputURL: outputURL,
            rendered: &rendered
        )
        try renderNotch(
            name: "watching.png",
            state: .watching,
            gaze: CGPoint(x: 0.6, y: -0.3),
            outputURL: outputURL,
            rendered: &rendered
        )
        try renderNotch(
            name: "angry.png",
            state: .angry,
            gaze: CGPoint(x: -0.4, y: 0.2),
            outputURL: outputURL,
            rendered: &rendered
        )
        try renderNotch(
            name: "angry-gaze-left.png",
            state: .angry,
            gaze: CGPoint(x: -0.8, y: 0.1),
            outputURL: outputURL,
            rendered: &rendered
        )
        try renderNotch(
            name: "idle-gaze-down.png",
            state: .idle,
            blinkProgress: 0,
            gaze: CGPoint(x: 0.3, y: 0.9),
            outputURL: outputURL,
            rendered: &rendered
        )
        try renderNotch(
            name: "happy.png",
            state: .happy,
            outputURL: outputURL,
            rendered: &rendered
        )
        try renderNotch(
            name: "tray-hidden.png",
            state: .idle,
            blinkProgress: 0,
            trayOffset: 40,
            outputURL: outputURL,
            rendered: &rendered
        )

        try renderBubble(
            name: "bubble.png",
            inputOpen: false,
            size: bubbleSize,
            outputURL: outputURL,
            rendered: &rendered
        )
        try renderBubble(
            name: "bubble-input.png",
            inputOpen: true,
            size: bubbleInputSize,
            outputURL: outputURL,
            rendered: &rendered
        )

        let sheet = try makeSheet(rendered)
        try writePNG(sheet, to: outputURL.appendingPathComponent("sheet.png"))
        return outputURL
    }

    private static func renderNotch(
        name: String,
        state: CompanionState,
        blinkProgress: CGFloat? = nil,
        gaze: CGPoint? = nil,
        trayOffset: CGFloat = 0,
        outputURL: URL,
        rendered: inout [(name: String, image: NSImage)]
    ) throws {
        let model = EyesModel()
        model.state = state
        let view = ZStack {
            background
            NotchPanelContent(
                model: model,
                notchHeight: 32,
                panelHeight: 40,
                trayOffset: trayOffset,
                blinkProgress: blinkProgress,
                gaze: gaze,
                animationsEnabled: false
            )
        }
        .frame(width: notchSize.width, height: notchSize.height)

        let image = try image(view, size: notchSize)
        try writePNG(image, to: outputURL.appendingPathComponent(name))
        rendered.append((name, image))
    }

    private static func renderBubble(
        name: String,
        inputOpen: Bool,
        size: CGSize,
        outputURL: URL,
        rendered: inout [(name: String, image: NSImage)]
    ) throws {
        let model = BubbleModel()
        model.replaceText("Close YouTube now.\nGet back to your essay.")
        if inputOpen {
            model.openInput()
            model.replyText = "I'm researching for the essay."
        }
        let view = ZStack(alignment: .top) {
            background
            BubbleView(
                model: model,
                staticHover: true,
                autoFocusInput: false,
                staticReplyText: inputOpen ? model.replyText : nil
            ) { _ in }
        }
        .frame(width: size.width, height: size.height, alignment: .top)

        let renderedImage = try image(view, size: size)
        try writePNG(renderedImage, to: outputURL.appendingPathComponent(name))
        rendered.append((name, renderedImage))
    }

    private static func image<V: View>(_ view: V, size: CGSize) throws -> NSImage {
        let renderer = ImageRenderer(
            content: view.environment(\.colorScheme, .dark)
        )
        renderer.proposedSize = ProposedViewSize(size)
        renderer.scale = 3
        guard let image = renderer.nsImage else {
            throw RenderError.imageCreationFailed
        }
        return image
    }

    private static func makeSheet(
        _ rendered: [(name: String, image: NSImage)]
    ) throws -> NSImage {
        let columns = 2
        let cellSize = CGSize(width: 360, height: 190)
        let rows = Int(ceil(Double(rendered.count) / Double(columns)))
        let sheetSize = CGSize(
            width: cellSize.width * CGFloat(columns),
            height: cellSize.height * CGFloat(rows)
        )
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(sheetSize.width * 3),
            pixelsHigh: Int(sheetSize.height * 3),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw RenderError.imageCreationFailed
        }
        representation.size = sheetSize
        guard let context = NSGraphicsContext(bitmapImageRep: representation) else {
            throw RenderError.imageCreationFailed
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor(calibratedWhite: 0.5, alpha: 1).setFill()
        NSBezierPath(rect: CGRect(origin: .zero, size: sheetSize)).fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        for (index, item) in rendered.enumerated() {
            let column = index % columns
            let row = index / columns
            let cellOrigin = CGPoint(
                x: CGFloat(column) * cellSize.width,
                y: sheetSize.height - CGFloat(row + 1) * cellSize.height
            )
            let labelRect = CGRect(
                x: cellOrigin.x + 16,
                y: cellOrigin.y + 12,
                width: cellSize.width - 32,
                height: 20
            )
            NSString(string: item.name).draw(in: labelRect, withAttributes: attributes)

            let available = CGRect(
                x: cellOrigin.x + 16,
                y: cellOrigin.y + 40,
                width: cellSize.width - 32,
                height: cellSize.height - 56
            )
            let destination = aspectFit(item.image.size, in: available)
            item.image.draw(
                in: destination,
                from: CGRect(origin: .zero, size: item.image.size),
                operation: .sourceOver,
                fraction: 1
            )
        }
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: sheetSize)
        image.addRepresentation(representation)
        return image
    }

    private static func aspectFit(_ size: CGSize, in rect: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let scale = min(rect.width / size.width, rect.height / size.height, 1)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(
            x: rect.midX - fitted.width / 2,
            y: rect.midY - fitted.height / 2,
            width: fitted.width,
            height: fitted.height
        )
    }

    private static func writePNG(_ image: NSImage, to url: URL) throws {
        guard let tiff = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiff),
              let png = representation.representation(using: .png, properties: [:]) else {
            throw RenderError.pngEncodingFailed
        }
        try png.write(to: url, options: .atomic)
    }
}

private enum RenderError: Error {
    case imageCreationFailed
    case pngEncodingFailed
}
