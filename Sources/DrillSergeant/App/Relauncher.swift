import Foundation

struct RelaunchCommand: Equatable {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
}

enum Relauncher {
    private static let waitScript = """
    parent_pid="$1"
    shift
    attempts=0
    while kill -0 "$parent_pid" 2>/dev/null && [ "$attempts" -lt 300 ]; do
        sleep 0.1
        attempts=$((attempts + 1))
    done
    if kill -0 "$parent_pid" 2>/dev/null; then
        exit 1
    fi
    exec "$@"
    """

    static func command(
        bundleURL: URL,
        executableURL: URL?,
        arguments: [String],
        parentProcessID: Int32,
        environment: [String: String]
    ) -> RelaunchCommand? {
        let targetExecutable: URL
        let targetArguments: [String]

        if bundleURL.pathExtension.localizedCaseInsensitiveCompare("app") == .orderedSame {
            targetExecutable = URL(fileURLWithPath: "/usr/bin/open")
            targetArguments = [bundleURL.path]
        } else {
            guard let executableURL else { return nil }
            targetExecutable = executableURL
            targetArguments = Array(arguments.dropFirst())
        }

        var cleanEnvironment = environment
        cleanEnvironment.removeValue(forKey: "DS_RESET_ONBOARDING")
        return command(
            targetExecutable: targetExecutable,
            targetArguments: targetArguments,
            parentProcessID: parentProcessID,
            environment: cleanEnvironment
        )
    }

    static func launch(_ command: RelaunchCommand) throws {
        let process = Process()
        process.executableURL = command.executableURL
        process.arguments = command.arguments
        process.environment = command.environment
        try process.run()
    }

    static func command(
        targetExecutable: URL,
        targetArguments: [String],
        parentProcessID: Int32,
        environment: [String: String]
    ) -> RelaunchCommand {
        RelaunchCommand(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                waitScript,
                "drill-sergeant-relauncher",
                String(parentProcessID),
                targetExecutable.path,
            ] + targetArguments,
            environment: environment
        )
    }
}

enum TerminationReason {
    static var currentQuitReason: AEEventID? {
        NSAppleEventManager.shared().currentAppleEvent?
            .paramDescriptor(forKeyword: AEKeyword(kAEQuitReason))?
            .enumCodeValue
    }

    static func endsLoginSession(_ reason: AEEventID?) -> Bool {
        guard let reason else { return false }
        return [kAEQuitAll, kAEShutDown, kAERestart, kAELogOut, kAEReallyLogOut]
            .contains(reason)
    }
}
