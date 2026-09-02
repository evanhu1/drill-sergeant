import AppKit
import CoreGraphics
import ScreenCaptureKit

enum ScreenPermission {
    /// What macOS has recorded, which is not the same as what this process can do. A binary run
    /// from a terminal inherits the terminal's grant, so this can report yes for a build that has
    /// never been granted anything. Treat it as a hint and confirm with `probe()`.
    static func isGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Whether capture actually works right now, answered by doing the real thing and throwing
    /// the result away. This is the only trustworthy answer, and on a first run it is also how
    /// the system prompt gets raised.
    static func probe() async -> Bool {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            return !content.displays.isEmpty
        } catch {
            return false
        }
    }

    static func request() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func openSystemSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
