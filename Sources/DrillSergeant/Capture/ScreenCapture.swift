import AppKit
import CoreGraphics
import ScreenCaptureKit

struct Screenshot {
    let jpegData: Data
    let width: Int
    let height: Int
    let capturedAt: Date

    var base64: String { jpegData.base64EncodedString() }
}

enum ScreenCaptureError: Error {
    case permissionDenied
    case noDisplay
    case failed(String)
}

enum ScreenCapture {
    /// Captures and downscales the display currently containing the mouse cursor.
    static func capture() async throws -> Screenshot {
        guard ScreenPermission.isGranted() else {
            throw ScreenCaptureError.permissionDenied
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            guard let display = displayAtCursor(from: content.displays) else {
                throw ScreenCaptureError.noDisplay
            }

            let ownPID = ProcessInfo.processInfo.processIdentifier
            let ownWindows = content.windows.filter {
                $0.owningApplication?.processID == ownPID
            }
            let filter = SCContentFilter(
                display: display,
                excludingWindows: ownWindows
            )
            let size = scaledSize(width: display.width, height: display.height)
            let configuration = SCStreamConfiguration()
            configuration.width = size.width
            configuration.height = size.height
            configuration.scalesToFit = true
            configuration.showsCursor = false

            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            guard let jpegData = jpegData(from: image) else {
                throw ScreenCaptureError.failed("Could not encode screenshot as JPEG")
            }

            return Screenshot(
                jpegData: jpegData,
                width: image.width,
                height: image.height,
                capturedAt: Date()
            )
        } catch let error as ScreenCaptureError {
            throw error
        } catch {
            if !ScreenPermission.isGranted() {
                throw ScreenCaptureError.permissionDenied
            }
            throw ScreenCaptureError.failed(error.localizedDescription)
        }
    }

    static func scaledSize(
        width: Int,
        height: Int,
        maxEdge: Int = 1280
    ) -> (width: Int, height: Int) {
        guard width > 0, height > 0, maxEdge > 0 else {
            return (max(1, width), max(1, height))
        }
        let longest = max(width, height)
        guard longest > maxEdge else { return (width, height) }

        let scale = Double(maxEdge) / Double(longest)
        return (
            max(1, Int((Double(width) * scale).rounded())),
            max(1, Int((Double(height) * scale).rounded()))
        )
    }

    private static func displayAtCursor(from displays: [SCDisplay]) -> SCDisplay? {
        let cursor = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(cursor) } ?? NSScreen.main
        let screenNumber = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
            as? NSNumber
        if let displayID = screenNumber?.uint32Value,
           let match = displays.first(where: { $0.displayID == displayID }) {
            return match
        }
        return displays.first
    }

    private static func jpegData(from image: CGImage) -> Data? {
        let representation = NSBitmapImageRep(cgImage: image)
        return representation.representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.7]
        )
    }
}
