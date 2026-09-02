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

struct TargetWindow: Equatable {
    let windowID: CGWindowID
    let owningProcessID: pid_t
    let appName: String
    let bundleID: String?
    let title: String?
}

enum ActiveWindowInspector {
    static func current() -> ActiveWindowInfo {
        guard let target = currentTarget() else {
            return ActiveWindowInfo(
                appName: "Unknown",
                bundleID: nil,
                windowTitle: nil
            )
        }

        return ActiveWindowInfo(
            appName: target.appName,
            bundleID: target.bundleID,
            windowTitle: target.title
        )
    }

    static func currentTarget() -> TargetWindow? {
        let workspace = NSWorkspace.shared
        let ownBundleID = Bundle.main.bundleIdentifier ?? "com.evanhu.drillsergeant"
        let applications = candidateApplications(
            workspace: workspace,
            ownBundleID: ownBundleID
        )
        let windows = onScreenWindows()

        for application in applications {
            if let window = windows.first(where: {
                ownerProcessID(of: $0) == application.processIdentifier
            }), let target = target(from: window, application: application) {
                return target
            }
        }

        for window in windows {
            guard let processID = ownerProcessID(of: window),
                  let application = NSRunningApplication(processIdentifier: processID),
                  application.bundleIdentifier != ownBundleID else {
                continue
            }
            if let target = target(from: window, application: application) {
                return target
            }
        }
        return nil
    }

    static func isEligibleWindow(bounds: CGRect) -> Bool {
        bounds.width >= 200 && bounds.height >= 150
    }

    private static func candidateApplications(
        workspace: NSWorkspace,
        ownBundleID: String
    ) -> [NSRunningApplication] {
        var applications: [NSRunningApplication] = []
        if let frontmost = workspace.frontmostApplication,
           frontmost.bundleIdentifier != ownBundleID {
            applications.append(frontmost)
        }

        let running = workspace.runningApplications.sorted {
            $0.isActive && !$1.isActive
        }
        for application in running where application.bundleIdentifier != ownBundleID {
            guard !applications.contains(where: {
                $0.processIdentifier == application.processIdentifier
            }) else {
                continue
            }
            applications.append(application)
        }
        return applications
    }

    private static func onScreenWindows() -> [[String: Any]] {
        let options: CGWindowListOption = [
            .optionOnScreenOnly,
            .excludeDesktopElements,
        ]
        guard let windowInfo = CGWindowListCopyWindowInfo(
            options,
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        return windowInfo.filter { window in
            guard let layer = window[kCGWindowLayer as String] as? NSNumber,
                  layer.intValue == 0,
                  let bounds = bounds(of: window) else {
                return false
            }
            return isEligibleWindow(bounds: bounds)
        }
    }

    private static func target(
        from window: [String: Any],
        application: NSRunningApplication
    ) -> TargetWindow? {
        guard let windowNumber = window[kCGWindowNumber as String] as? NSNumber,
              let processID = ownerProcessID(of: window) else {
            return nil
        }
        let appName = application.localizedName
            ?? application.bundleURL?.deletingPathExtension().lastPathComponent
            ?? window[kCGWindowOwnerName as String] as? String
            ?? "Unknown"
        let rawTitle = window[kCGWindowName as String] as? String
        let title = rawTitle?.trimmingCharacters(in: .whitespacesAndNewlines)

        return TargetWindow(
            windowID: CGWindowID(windowNumber.uint32Value),
            owningProcessID: processID,
            appName: appName,
            bundleID: application.bundleIdentifier,
            title: title?.isEmpty == false ? title : nil
        )
    }

    private static func ownerProcessID(of window: [String: Any]) -> pid_t? {
        let ownerPID = window[kCGWindowOwnerPID as String] as? NSNumber
        return ownerPID?.int32Value
    }

    private static func bounds(of window: [String: Any]) -> CGRect? {
        guard let dictionary = window[kCGWindowBounds as String] as? [String: Any] else {
            return nil
        }
        return CGRect(dictionaryRepresentation: dictionary as CFDictionary)
    }
}
