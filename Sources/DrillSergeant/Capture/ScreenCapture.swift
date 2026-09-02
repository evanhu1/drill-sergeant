import AppKit
import CoreGraphics
import ScreenCaptureKit

enum CaptureSource: Equatable {
    case window(String)
    case display
}

struct Screenshot {
    let jpegData: Data
    let width: Int
    let height: Int
    let capturedAt: Date
    let source: CaptureSource

    var base64: String { jpegData.base64EncodedString() }
}

enum ScreenCaptureError: Error {
    case permissionDenied
    case noDisplay
    case failed(String)
}

enum ScreenCapture {
    /// The stages `--benchmark` times. Nothing observes them in a normal run.
    enum Stage: String {
        case shareableContent
        case captureImage
        case encode
    }

    /// Set only by the benchmark harness; nil in production, so this costs one nil check.
    nonisolated(unsafe) static var stageObserver: (@Sendable (Stage, TimeInterval) -> Void)?

    private static func timed<T>(_ stage: Stage, _ work: () throws -> T) rethrows -> T {
        guard stageObserver != nil else { return try work() }
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let value = try work()
        report(stage, since: startedAt)
        return value
    }

    private static func report(_ stage: Stage, since startedAt: UInt64) {
        let elapsed = DispatchTime.now().uptimeNanoseconds &- startedAt
        stageObserver?(stage, Double(elapsed) / 1_000_000_000)
    }

    /// Captures the active window, falling back to the display at the cursor.
    static func capture() async throws -> Screenshot {
        guard ScreenPermission.isGranted() else {
            throw ScreenCaptureError.permissionDenied
        }

        do {
            let contentStartedAt = DispatchTime.now().uptimeNanoseconds
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            report(.shareableContent, since: contentStartedAt)

            if let target = ActiveWindowInspector.currentTarget() {
                if let window = content.windows.first(where: {
                    $0.windowID == target.windowID
                }) {
                    do {
                        Log.info("Using window capture for \"\(target.appName)\"")
                        return try await capture(window: window, target: target)
                    } catch {
                        Log.info(
                            "Window capture for \"\(target.appName)\" failed; "
                                + "falling back to display: \(error.localizedDescription)"
                        )
                    }
                } else {
                    Log.info(
                        "Target window for \"\(target.appName)\" is not shareable; "
                            + "falling back to display"
                    )
                }
            } else {
                Log.info("No eligible target window; falling back to display")
            }
            Log.info("Using display capture fallback")
            return try await captureDisplay(from: content)
        } catch let error as ScreenCaptureError {
            throw error
        } catch {
            if !ScreenPermission.isGranted() {
                throw ScreenCaptureError.permissionDenied
            }
            throw ScreenCaptureError.failed(error.localizedDescription)
        }
    }

    private static func capture(
        window: SCWindow,
        target: TargetWindow
    ) async throws -> Screenshot {
        let width = max(1, Int(window.frame.width.rounded()))
        let height = max(1, Int(window.frame.height.rounded()))
        let size = scaledSize(
            width: width,
            height: height,
            maxEdge: RuntimeProfile.current.screenshotMaxEdge
        )
        let configuration = configuration(for: size)
        let backgroundColor = CGColor(gray: 0, alpha: 1)
        configuration.backgroundColor = backgroundColor
        defer { withExtendedLifetime(backgroundColor) {} }
        let filter = SCContentFilter(desktopIndependentWindow: window)

        return try await screenshot(
            filter: filter,
            configuration: configuration,
            source: .window(target.appName)
        )
    }

    private static func captureDisplay(
        from content: SCShareableContent
    ) async throws -> Screenshot {
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
        let size = scaledSize(
            width: display.width,
            height: display.height,
            maxEdge: RuntimeProfile.current.screenshotMaxEdge
        )
        return try await screenshot(
            filter: filter,
            configuration: configuration(for: size),
            source: .display
        )
    }

    private static func configuration(
        for size: (width: Int, height: Int)
    ) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = size.width
        configuration.height = size.height
        configuration.scalesToFit = true
        configuration.showsCursor = false
        return configuration
    }

    private static func screenshot(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration,
        source: CaptureSource
    ) async throws -> Screenshot {
        let imageStartedAt = DispatchTime.now().uptimeNanoseconds
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        report(.captureImage, since: imageStartedAt)
        guard let jpegData = timed(.encode, { jpegData(from: image) }) else {
            throw ScreenCaptureError.failed("Could not encode screenshot as JPEG")
        }

        return Screenshot(
            jpegData: jpegData,
            width: image.width,
            height: image.height,
            capturedAt: Date(),
            source: source
        )
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
