import Foundation
import OSLog

enum Log {
    private static let logger = Logger(
        subsystem: "com.evanhu.drillsergeant",
        category: "app"
    )
    private static let fileLock = NSLock()
    private static let maximumFileSize: UInt64 = 5 * 1_024 * 1_024

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        append(level: "INFO", message: message)
    }

    static func warn(_ message: String) {
        logger.warning("\(message, privacy: .public)")
        append(level: "WARN", message: message)
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        append(level: "ERROR", message: message)
    }

    private static func append(level: String, message: String) {
        fileLock.lock()
        defer { fileLock.unlock() }

        let fileManager = FileManager.default
        let directory = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DrillSergeant", isDirectory: true)
        let file = directory.appendingPathComponent("app.log")

        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try rotateIfNeeded(file, fileManager: fileManager)
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let sanitized = message.replacingOccurrences(of: "\n", with: " ")
            guard let data = "\(timestamp) [\(level)] \(sanitized)\n".data(using: .utf8) else {
                return
            }
            if !fileManager.fileExists(atPath: file.path) {
                fileManager.createFile(atPath: file.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // Unified logging remains available if the file cannot be written.
        }
    }

    private static func rotateIfNeeded(_ file: URL, fileManager: FileManager) throws {
        guard let attributes = try? fileManager.attributesOfItem(atPath: file.path),
              let size = attributes[.size] as? NSNumber,
              size.uint64Value >= maximumFileSize else {
            return
        }
        let rotated = file.appendingPathExtension("1")
        if fileManager.fileExists(atPath: rotated.path) {
            try fileManager.removeItem(at: rotated)
        }
        try fileManager.moveItem(at: file, to: rotated)
    }
}
