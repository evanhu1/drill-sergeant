import AppKit
import Darwin

enum AppMain {
    static func run() {
        MainActor.assumeIsolated {
            if let outputURL = renderOutputURL(arguments: CommandLine.arguments) {
                _ = NSApplication.shared
                do {
                    _ = try StateRenderer.render(to: outputURL)
                    exit(EXIT_SUCCESS)
                } catch {
                    Log.error("State rendering failed: \(error.localizedDescription)")
                    exit(EXIT_FAILURE)
                }
            }

            let application = NSApplication.shared
            let delegate = AppDelegate()
            application.setActivationPolicy(.accessory)
            application.delegate = delegate
            application.run()
            withExtendedLifetime(delegate) {}
        }
    }

    private static func renderOutputURL(arguments: [String]) -> URL? {
        guard let index = arguments.firstIndex(of: "--render-states") else { return nil }
        let pathIndex = arguments.index(after: index)
        guard pathIndex < arguments.endIndex,
              !arguments[pathIndex].hasPrefix("--") else {
            return StateRenderer.defaultOutputURL
        }
        return URL(
            fileURLWithPath: arguments[pathIndex],
            relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        ).standardizedFileURL
    }
}
