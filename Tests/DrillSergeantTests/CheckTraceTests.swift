import XCTest
@testable import DrillSergeant

final class CheckTraceTests: XCTestCase {
    func testPromptListsMessagesInOrderWithoutBase64() throws {
        let base64 = "VGhpcyBpcyBub3QgZm9yIHRoZSB0cmFjZS4="
        let request = makeRequest(
            messages: [
                OllamaMessage(role: "system", content: "System prompt", images: nil),
                OllamaMessage(role: "user", content: "Screenshot attached.", images: [base64]),
                OllamaMessage(role: "assistant", content: "Earlier decision", images: nil),
            ]
        )

        let prompt = CheckTrace.formatPrompt(request)

        let system = try XCTUnwrap(prompt.range(of: "--- message 1 · system"))
        let user = try XCTUnwrap(
            prompt.range(of: "--- message 2 · user · [image: screenshot.jpg]")
        )
        let assistant = try XCTUnwrap(prompt.range(of: "--- message 3 · assistant"))
        XCTAssertLessThan(system.lowerBound, user.lowerBound)
        XCTAssertLessThan(user.lowerBound, assistant.lowerBound)
        XCTAssertTrue(prompt.contains("System prompt"))
        XCTAssertTrue(prompt.contains("Screenshot attached."))
        XCTAssertTrue(prompt.contains("Earlier decision"))
        XCTAssertFalse(prompt.contains(base64))
    }

    func testResponseFileFormatsSuccessAndError() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let trace = CheckTrace(directory: directory)
        let result = OllamaDecisionResult(
            decision: Decision(
                tool: .set_angry,
                snoozeMinutes: nil,
                message: "Close it and get back to work."
            ),
            latency: 4.12,
            sourceField: "content",
            rawContent: #"{"message":{"role":"assistant","content":"Close it and get back to work.","tool_calls":[{"function":{"name":"set_angry","arguments":{}}}]}}"#,
            evalCount: 30,
            doneReason: "stop",
            conversationMessages: []
        )

        let successFolder = try trace.write(
            request: makeRequest(),
            response: .success(result),
            screenshotData: Data([0xFF, 0xD8, 0xFF])
        )
        let success = try String(
            contentsOf: successFolder.appendingPathComponent("response.txt"),
            encoding: .utf8
        )
        XCTAssertTrue(success.contains("latency: 4.12s"))
        XCTAssertTrue(success.contains("source: content"))
        XCTAssertTrue(success.contains("eval_count: 30"))
        XCTAssertTrue(success.contains("done_reason: stop"))
        XCTAssertTrue(success.contains("--- raw\n\(result.rawContent)"))
        XCTAssertTrue(success.contains("--- parsed\ntool: set_angry"))
        XCTAssertTrue(success.contains("assistant_text: Close it and get back to work."))

        let failureFolder = try trace.write(
            request: makeRequest(reason: .reply, capture: nil),
            response: .failure(
                error: "bad response: invalid JSON",
                latency: 1.5,
                rawContent: "not json"
            ),
            screenshotData: nil
        )
        let failure = try String(
            contentsOf: failureFolder.appendingPathComponent("response.txt"),
            encoding: .utf8
        )
        XCTAssertEqual(
            failure,
            "latency: 1.50s\nerror: bad response: invalid JSON\n\n--- raw\nnot json\n"
        )
    }

    func testRetentionPrunesToOneHundredFolders() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let trace = CheckTrace(directory: directory)

        for offset in 0..<101 {
            let request = makeRequest(
                time: Date(timeIntervalSince1970: 1_800_000_000 + Double(offset))
            )
            _ = try trace.write(
                request: request,
                response: failureResponse,
                screenshotData: Data([0x01])
            )
        }

        let folders = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey]
        ).filter {
            try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        }
        XCTAssertEqual(folders.count, 100)
    }

    func testNameCollisionUsesSecondSuffix() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let trace = CheckTrace(directory: directory)
        let request = makeRequest()

        let first = try trace.write(
            request: request,
            response: failureResponse,
            screenshotData: Data([0x01])
        )
        let second = try trace.write(
            request: request,
            response: failureResponse,
            screenshotData: Data([0x01])
        )

        XCTAssertEqual(second.lastPathComponent, first.lastPathComponent + "-2")
    }

    private var failureResponse: CheckTrace.Response {
        .failure(error: "unreachable", latency: nil, rawContent: nil)
    }

    private func makeRequest(
        reason: CheckTrace.Reason = .scheduled,
        time: Date = Date(timeIntervalSince1970: 1_788_349_265),
        capture: CheckTrace.Capture? = CheckTrace.Capture(
            description: "window \"Arc\"",
            width: 1_280,
            height: 803,
            byteCount: 118_784
        ),
        messages: [OllamaMessage] = [
            OllamaMessage(role: "system", content: "System", images: nil),
            OllamaMessage(role: "user", content: "User", images: ["base64"]),
        ]
    ) -> CheckTrace.Request {
        CheckTrace.Request(
            reason: reason,
            time: time,
            model: "qwen3-vl:8b",
            state: .watching,
            previousState: .idle,
            stateAge: 2,
            capture: capture,
            activeWindow: ActiveWindowInfo(
                appName: "Arc",
                bundleID: "company.thebrowser.Browser",
                windowTitle: "Week of September 7, 2026"
            ),
            messages: messages
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("CheckTraceTests-\(UUID().uuidString)", isDirectory: true)
    }
}
