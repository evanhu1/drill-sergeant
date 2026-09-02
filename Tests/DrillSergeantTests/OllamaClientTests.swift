import XCTest
@testable import DrillSergeant

final class OllamaClientTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    func testHasModelMatchesLatestSuffix() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/tags")
            return Self.response(
                request: request,
                body: #"{"models":[{"name":"qwen3-vl:8b:latest"}]}"#
            )
        }
        let client = makeClient(model: "qwen3-vl:8b")

        let hasModel = try await client.hasModel()
        XCTAssertTrue(hasModel)
    }

    func testDecideSendsNativeToolsAndUsesAssistantContent() async throws {
        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            XCTAssertEqual(request.url?.path, "/api/chat")
            XCTAssertEqual(request.httpMethod, "POST")
            let object = try Self.bodyObject(from: request)
            XCTAssertEqual(object["stream"] as? Bool, false)
            XCTAssertNil(object["think"])
            XCTAssertEqual(object["keep_alive"] as? String, "30m")
            XCTAssertNil(object["format"])
            XCTAssertEqual((object["tools"] as? [[String: Any]])?.count, 5)
            let options = try XCTUnwrap(object["options"] as? [String: Any])
            XCTAssertEqual(options["num_ctx"] as? Int, 8_192)
            XCTAssertNil(options["num_predict"])
            return Self.response(
                request: request,
                body: #"{"message":{"role":"assistant","content":"Close it.","thinking":"private reasoning","tool_calls":[{"function":{"name":"set_angry","arguments":{}}}]},"eval_count":18,"done_reason":"stop"}"#
            )
        }
        let client = makeClient()

        let result = try await client.decideWithMetadata(
            messages: [OllamaMessage(role: "user", content: "Check", images: ["abc"])]
        )

        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(
            result.decision,
            Decision(tool: .set_angry, snoozeMinutes: nil, message: "Close it.")
        )
        XCTAssertEqual(result.sourceField, "content")
        XCTAssertEqual(result.evalCount, 18)
        XCTAssertEqual(result.doneReason, "stop")
        XCTAssertEqual(result.conversationMessages.map(\.role), ["assistant", "tool"])
        XCTAssertNil(result.conversationMessages.first?.thinking)
    }

    func testEmptyToolCallContentGetsNormalAssistantFollowUp() async throws {
        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            let object = try Self.bodyObject(from: request)
            if requestCount == 1 {
                XCTAssertNotNil(object["tools"])
                return Self.response(
                    request: request,
                    body: #"{"message":{"role":"assistant","content":"","tool_calls":[{"id":"call-1","type":"function","function":{"index":0,"name":"set_work_hours","arguments":{"days":["monday","tuesday","wednesday","thursday","friday"],"start_time":"09:00","end_time":"17:00"}}}]},"eval_count":20,"done_reason":"stop"}"#
                )
            }

            XCTAssertNil(object["tools"])
            let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
            XCTAssertEqual(messages.suffix(2).map { $0["role"] as? String }, ["assistant", "tool"])
            XCTAssertNil(messages.first?["images"])
            XCTAssertEqual(messages.last?["tool_name"] as? String, "set_work_hours")
            XCTAssertEqual(messages.last?["tool_call_id"] as? String, "call-1")
            let options = try XCTUnwrap(object["options"] as? [String: Any])
            XCTAssertNil(options["num_predict"])
            return Self.response(
                request: request,
                body: #"{"message":{"role":"assistant","content":"Weekdays, nine to five.","thinking":"private reasoning"},"eval_count":10,"done_reason":"stop"}"#
            )
        }
        let client = makeClient()

        let result = try await client.decideWithMetadata(
            messages: [OllamaMessage(role: "user", content: "Set my hours", images: ["abc"])]
        )

        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(result.decision.tool, .set_work_hours)
        XCTAssertEqual(result.decision.workHours, .standard)
        XCTAssertEqual(result.decision.message, "Weekdays, nine to five.")
        XCTAssertEqual(result.sourceField, "followup.content")
        XCTAssertEqual(result.evalCount, 30)
        XCTAssertEqual(
            result.conversationMessages.map(\.role),
            ["assistant", "tool", "assistant"]
        )
        XCTAssertTrue(result.conversationMessages.allSatisfy { $0.thinking == nil })
        XCTAssertTrue(result.rawContent.contains("--- follow-up response"))
    }

    func testEmptySetIdleContentStaysSilentWithoutFollowUp() async throws {
        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            return Self.response(
                request: request,
                body: #"{"message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"set_idle","arguments":{}}}]}}"#
            )
        }
        let client = makeClient()

        let decision = try await client.decide(messages: [])

        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(decision.tool, .set_idle)
        XCTAssertEqual(decision.message, "")
    }

    func testLowMemoryUsesSmallerContextAndUnloadsAfterSetIdle() async throws {
        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            let object = try Self.bodyObject(from: request)
            if requestCount == 1 {
                XCTAssertEqual(object["keep_alive"] as? String, "30s")
                let options = try XCTUnwrap(object["options"] as? [String: Any])
                XCTAssertEqual(options["num_ctx"] as? Int, 4_096)
                return Self.response(
                    request: request,
                    body: #"{"message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"set_idle","arguments":{}}}]}}"#
                )
            }

            XCTAssertEqual(request.url?.path, "/api/generate")
            XCTAssertEqual(object["keep_alive"] as? Int, 0)
            XCTAssertNil(object["messages"])
            return Self.response(
                request: request,
                body: #"{"message":{"role":"assistant","content":""},"done":true}"#
            )
        }
        let client = makeClient(runtimeProfile: .lowMemory)

        let decision = try await client.decide(messages: [])

        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(decision.tool, .set_idle)
    }

    func testLowMemoryUnloadsOnFinalFollowUpRequest() async throws {
        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            let object = try Self.bodyObject(from: request)
            if requestCount == 1 {
                XCTAssertEqual(object["keep_alive"] as? String, "30s")
                return Self.response(
                    request: request,
                    body: #"{"message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"set_angry","arguments":{}}}]}}"#
                )
            }

            XCTAssertEqual(object["keep_alive"] as? Int, 0)
            XCTAssertNil(object["tools"])
            return Self.response(
                request: request,
                body: #"{"message":{"role":"assistant","content":"Back to work."}}"#
            )
        }
        let client = makeClient(runtimeProfile: .lowMemory)

        let decision = try await client.decide(messages: [])

        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(decision.message, "Back to work.")
    }

    func testMissingNativeToolCallIsRejected() async {
        MockURLProtocol.handler = { request in
            Self.response(
                request: request,
                body: #"{"message":{"role":"assistant","content":"Just text."}}"#
            )
        }
        let client = makeClient()

        do {
            _ = try await client.decide(messages: [])
            XCTFail("Expected badResponse")
        } catch let error as OllamaError {
            guard case let .badResponse(message) = error else {
                return XCTFail("Expected badResponse, got \(error)")
            }
            XCTAssertTrue(message.contains("exactly one native tool call"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testIsReachableReturnsFalseForTransportError() async {
        MockURLProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }
        let client = makeClient()
        let reachable = await client.isReachable()
        XCTAssertFalse(reachable)
    }

    func testMissingModelMapsToModelMissingError() async {
        MockURLProtocol.handler = { request in
            Self.response(request: request, status: 404, body: #"{"error":"model not found"}"#)
        }
        let client = makeClient(model: "missing:model")

        do {
            _ = try await client.decide(messages: [])
            XCTFail("Expected modelMissing")
        } catch let error as OllamaError {
            XCTAssertEqual(error, .modelMissing("missing:model"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeClient(
        model: String = "qwen3-vl:8b",
        runtimeProfile: RuntimeProfile = .standard
    ) -> OllamaClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return OllamaClient(
            baseURL: URL(string: "http://ollama.test")!,
            model: model,
            session: session,
            runtimeProfile: runtimeProfile
        )
    }

    private static func bodyObject(from request: URLRequest) throws -> [String: Any] {
        let body = try XCTUnwrap(bodyData(from: request))
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
    }

    private static func response(
        request: URLRequest,
        status: Int = 200,
        body: String
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(body.utf8))
    }

    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }

        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4_096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            guard count >= 0 else { return nil }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
