import AppKit
import CoreGraphics

struct ActiveWindowInfo: Equatable {
    let appName: String
    let bundleID: String?
    let windowTitle: String?

    var summary: String {
        guard let windowTitle, !windowTitle.isEmpty else { return appName }
        return "\(appName) — “\(windowTitle)”"
    }

    var looksLikeYouTube: Bool {
        windowTitle?.localizedCaseInsensitiveContains("youtube") == true
            || bundleID?.localizedCaseInsensitiveContains("youtube") == true
    }
}

enum ActiveWindowInspector {
    static func current() -> ActiveWindowInfo {
        guard let application = NSWorkspace.shared.frontmostApplication else {
            return ActiveWindowInfo(
                appName: "Unknown",
                bundleID: nil,
                windowTitle: nil
            )
        }

        let appName = application.localizedName
            ?? application.bundleURL?.deletingPathExtension().lastPathComponent
            ?? "Unknown"
        return ActiveWindowInfo(
            appName: appName,
            bundleID: application.bundleIdentifier,
            windowTitle: windowTitle(for: application.processIdentifier)
        )
    }

    private static func windowTitle(for processID: pid_t) -> String? {
        let options: CGWindowListOption = [
            .optionOnScreenOnly,
            .excludeDesktopElements,
        ]
        guard let windowInfo = CGWindowListCopyWindowInfo(
            options,
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        for window in windowInfo {
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? NSNumber,
                  ownerPID.int32Value == processID,
                  let layer = window[kCGWindowLayer as String] as? NSNumber,
                  layer.intValue == 0,
                  let title = window[kCGWindowName as String] as? String,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            return title
        }
        return nil
    }
}
