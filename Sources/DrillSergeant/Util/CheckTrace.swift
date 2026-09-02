import Foundation

/// A human-readable record of one model request and its outcome.
struct CheckTrace {
    enum Reason: String {
        case scheduled
        case angryPoll
        case manual
        case onboarding
        case reply

        init(_ reason: CheckReason) {
            switch reason {
            case .scheduled: self = .scheduled
            case .angryPoll: self = .angryPoll
            case .manual: self = .manual
            case .onboarding: self = .onboarding
            }
        }
    }

    struct Capture: Equatable {
        let description: String
        let width: Int
        let height: Int
        let byteCount: Int
    }

    struct Request: Equatable {
        let reason: Reason
        let time: Date
        let model: String
        let state: CompanionState
        let previousState: CompanionState
        let stateAge: TimeInterval
        let capture: Capture?
        let activeWindow: ActiveWindowInfo
        let messages: [OllamaMessage]
    }

    enum Response: Equatable {
        case success(OllamaDecisionResult)
        case failure(error: String, latency: TimeInterval?, rawContent: String?)
    }

    static let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/DrillSergeant/checks", isDirectory: true)

    let directory: URL
    private let fileManager: FileManager
    private let retentionLimit: Int

    init(
        directory: URL = CheckTrace.defaultDirectory,
        fileManager: FileManager = .default,
        retentionLimit: Int = 100
    ) {
        self.directory = directory
        self.fileManager = fileManager
        self.retentionLimit = retentionLimit
    }

    /// Writes one complete trace folder and applies the retention limit.
    @discardableResult
    func write(
        request: Request,
        response: Response,
        screenshotData: Data?
    ) throws -> URL {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let traceDirectory = try availableDirectory(for: request)
        try fileManager.createDirectory(at: traceDirectory, withIntermediateDirectories: false)

        do {
            if let screenshotData {
                try screenshotData.write(
                    to: traceDirectory.appendingPathComponent("screenshot.jpg"),
                    options: .atomic
                )
            }
            try Self.formatPrompt(request).write(
                to: traceDirectory.appendingPathComponent("prompt.txt"),
                atomically: true,
                encoding: .utf8
            )
            try Self.formatResponse(response).write(
                to: traceDirectory.appendingPathComponent("response.txt"),
                atomically: true,
                encoding: .utf8
            )
        } catch {
            try? fileManager.removeItem(at: traceDirectory)
            throw error
        }
        try pruneOldTraces()
        return traceDirectory
    }

    /// Creates the trace root when a caller needs to reveal it in Finder.
    func createDirectoryIfNeeded() throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Formats prompt.txt without exposing image data.
    static func formatPrompt(_ request: Request) -> String {
        var lines = [
            "check: \(request.reason.rawValue)",
            "time: \(formatTraceTime(request.time))",
            "model: \(request.model)",
            "state: \(request.state.rawValue) (for \(formatAge(request.stateAge))), previous \(request.previousState.rawValue)",
            "capture: \(formatCapture(request.capture, reason: request.reason))",
            "active window: \(request.activeWindow.summary)",
        ]

        for (offset, message) in request.messages.enumerated() {
            let hasImage = request.capture != nil && message.images?.isEmpty == false
            let imageSuffix = hasImage ? " · [image: screenshot.jpg]" : ""
            lines.append("")
            lines.append("--- message \(offset + 1) · \(message.role)\(imageSuffix)")
            lines.append(message.content)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Formats response.txt for either a parsed result or a failed request.
    static func formatResponse(_ response: Response) -> String {
        switch response {
        case let .success(result):
            return [
                String(format: "latency: %.2fs", result.latency),
                "field: message.\(result.sourceField)",
                "eval_count: \(result.evalCount.map(String.init) ?? "none")",
                "done_reason: \(result.doneReason ?? "none")",
                "",
                "--- raw",
                result.rawContent,
                "",
                "--- parsed",
                "tool: \(result.decision.tool.rawValue)",
                "snooze_minutes: \(result.decision.snoozeMinutes.map(String.init) ?? "none")",
                "text: \(result.decision.text ?? "none")",
                "message: \(result.decision.message)",
            ].joined(separator: "\n") + "\n"

        case let .failure(error, latency, rawContent):
            var lines: [String] = []
            if let latency {
                lines.append(String(format: "latency: %.2fs", latency))
            }
            lines.append("error: \(error)")
            if let rawContent, !rawContent.isEmpty {
                lines.append("")
                lines.append("--- raw")
                lines.append(rawContent)
            }
            return lines.joined(separator: "\n") + "\n"
        }
    }

    static func capture(from screenshot: Screenshot) -> Capture {
        let description: String
        switch screenshot.source {
        case let .window(appName): description = "window \"\(appName)\""
        case .display: description = "display"
        }
        return Capture(
            description: description,
            width: screenshot.width,
            height: screenshot.height,
            byteCount: screenshot.jpegData.count
        )
    }

    private func availableDirectory(for request: Request) throws -> URL {
        let baseName = "\(Self.formatFolderTime(request.time))_\(request.reason.rawValue)"
        var suffix = 1
        while true {
            let name = suffix == 1 ? baseName : "\(baseName)-\(suffix)"
            let candidate = directory.appendingPathComponent(name, isDirectory: true)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            suffix += 1
        }
    }

    private func pruneOldTraces() throws {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey]
        let contents = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )
        let folders = contents.compactMap { url -> (URL, Date)? in
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isDirectory == true else {
                return nil
            }
            return (url, values.contentModificationDate ?? .distantPast)
        }.sorted {
            if $0.1 == $1.1 { return $0.0.lastPathComponent < $1.0.lastPathComponent }
            return $0.1 < $1.1
        }

        for (url, _) in folders.prefix(max(0, folders.count - retentionLimit)) {
            try fileManager.removeItem(at: url)
        }
    }

    private static func formatFolderTime(_ date: Date) -> String {
        formatter("yyyy-MM-dd_HH-mm-ss").string(from: date)
    }

    private static func formatTraceTime(_ date: Date) -> String {
        formatter("yyyy-MM-dd HH:mm:ss").string(from: date)
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = format
        return formatter
    }

    private static func formatAge(_ age: TimeInterval) -> String {
        let seconds = max(0, Int(age))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainder = seconds % 60
        if hours > 0 {
            return remainder > 0
                ? "\(hours)h \(minutes)m \(remainder)s"
                : "\(hours)h \(minutes)m"
        }
        if minutes > 0 {
            return remainder > 0 ? "\(minutes)m \(remainder)s" : "\(minutes)m"
        }
        return "\(remainder)s"
    }

    private static func formatCapture(_ capture: Capture?, reason: Reason) -> String {
        guard let capture else {
            return reason == .reply ? "none (reply)" : "none"
        }
        let kilobytes = Int((Double(capture.byteCount) / 1_024).rounded())
        return "\(capture.description) \(capture.width)x\(capture.height), \(kilobytes) KB"
    }
}
