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

            if CommandLine.arguments.contains("--dump-payload") {
                CheckBenchmark.dumpPayload()
            }

            if let runs = benchmarkRuns(arguments: CommandLine.arguments) {
                _ = NSApplication.shared
                Task { await CheckBenchmark.run(runs: runs) }
                RunLoop.main.run()
            }

            let application = NSApplication.shared
            let delegate = AppDelegate()
            application.setActivationPolicy(.accessory)
            application.delegate = delegate
            application.run()
            withExtendedLifetime(delegate) {}
        }
    }

    /// `--benchmark [runs]` times one whole check. Defaults to five runs.
    private static func benchmarkRuns(arguments: [String]) -> Int? {
        guard let index = arguments.firstIndex(of: "--benchmark") else { return nil }
        let next = arguments.index(after: index)
        guard next < arguments.endIndex, let runs = Int(arguments[next]) else { return 5 }
        return max(1, runs)
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
