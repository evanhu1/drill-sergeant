import XCTest
@testable import DrillSergeant

final class RelauncherTests: XCTestCase {
    func testBundleCommandWaitsForParentThenUsesLaunchServices() throws {
        let command = try XCTUnwrap(
            Relauncher.command(
                bundleURL: URL(fileURLWithPath: "/Applications/Drill Sergeant.app"),
                executableURL: nil,
                arguments: ["DrillSergeant"],
                parentProcessID: 42,
                environment: ["DS_RESET_ONBOARDING": "1", "KEEP": "yes"]
            )
        )

        XCTAssertEqual(command.executableURL.path, "/bin/sh")
        XCTAssertEqual(
            Array(command.arguments.suffix(3)),
            ["42", "/usr/bin/open", "/Applications/Drill Sergeant.app"]
        )
        XCTAssertNil(command.environment["DS_RESET_ONBOARDING"])
        XCTAssertEqual(command.environment["KEEP"], "yes")
    }

    func testExecutableCommandPreservesArguments() throws {
        let command = try XCTUnwrap(
            Relauncher.command(
                bundleURL: URL(fileURLWithPath: "/tmp/debug-build"),
                executableURL: URL(fileURLWithPath: "/tmp/debug-build/DrillSergeant"),
                arguments: ["DrillSergeant", "--example"],
                parentProcessID: 84,
                environment: [:]
            )
        )

        XCTAssertEqual(
            Array(command.arguments.suffix(3)),
            ["84", "/tmp/debug-build/DrillSergeant", "--example"]
        )
    }

    func testLaunchedHelperWaitsUntilParentExits() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelauncherTests.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let sentinel = directory.appendingPathComponent("replacement-started")

        let parent = Process()
        parent.executableURL = URL(fileURLWithPath: "/bin/sh")
        parent.arguments = ["-c", "sleep 0.25"]
        try parent.run()

        let command = Relauncher.command(
            targetExecutable: URL(fileURLWithPath: "/bin/sh"),
            targetArguments: [
                "-c",
                "printf ready > \"$1\"",
                "replacement",
                sentinel.path,
            ],
            parentProcessID: parent.processIdentifier,
            environment: ProcessInfo.processInfo.environment
        )
        try Relauncher.launch(command)

        XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path))
        parent.waitUntilExit()
        waitUntil { FileManager.default.fileExists(atPath: sentinel.path) }
        XCTAssertEqual(try String(contentsOf: sentinel), "ready")
    }

    func testTerminationReasonRecognizesSessionEndingEvents() {
        XCTAssertFalse(TerminationReason.endsLoginSession(nil))
        XCTAssertFalse(TerminationReason.endsLoginSession(kAEQuitApplication))
        XCTAssertTrue(TerminationReason.endsLoginSession(kAEQuitAll))
        XCTAssertTrue(TerminationReason.endsLoginSession(kAEShutDown))
        XCTAssertTrue(TerminationReason.endsLoginSession(kAERestart))
        XCTAssertTrue(TerminationReason.endsLoginSession(kAELogOut))
        XCTAssertTrue(TerminationReason.endsLoginSession(kAEReallyLogOut))
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(condition(), "Timed out waiting for replacement helper")
    }
}
