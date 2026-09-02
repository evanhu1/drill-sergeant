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

    func testDecideSendsStructuredRequestAndParsesDecision() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/chat")
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try XCTUnwrap(Self.bodyData(from: request))
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            XCTAssertEqual(object["stream"] as? Bool, false)
            XCTAssertEqual(object["think"] as? Bool, false)
            XCTAssertEqual(object["keep_alive"] as? String, "30m")
            XCTAssertNotNil(object["format"] as? [String: Any])
            let options = try XCTUnwrap(object["options"] as? [String: Any])
            XCTAssertEqual(options["num_predict"] as? Int, 200)
            return Self.response(
                request: request,
                body: #"{"message":{"content":"{\"tool\":\"set_angry\",\"message\":\"Close it.\"}"}}"#
            )
        }
        let client = makeClient()

        let decision = try await client.decide(
            messages: [OllamaMessage(role: "user", content: "Check", images: ["abc"])]
        )

        XCTAssertEqual(
            decision,
            Decision(tool: .set_angry, snoozeMinutes: nil, message: "Close it.")
        )
    }

    func testDecideFallsBackToThinkingField() async throws {
        MockURLProtocol.handler = { request in
            Self.response(
                request: request,
                body: #"{"message":{"content":"","thinking":"{\"tool\":\"set_idle\",\"message\":\"Good.\"}"},"eval_count":18,"done_reason":"stop"}"#
            )
        }
        let client = makeClient()

        let result = try await client.decideWithMetadata(messages: [])

        XCTAssertEqual(
            result.decision,
            Decision(tool: .set_idle, snoozeMinutes: nil, message: "Good.")
        )
        XCTAssertEqual(result.sourceField, "thinking")
        XCTAssertEqual(
            result.rawContent,
            #"{"tool":"set_idle","message":"Good."}"#
        )
        XCTAssertEqual(result.evalCount, 18)
        XCTAssertEqual(result.doneReason, "stop")
        XCTAssertGreaterThanOrEqual(result.latency, 0)
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

    private func makeClient(model: String = "qwen3-vl:8b") -> OllamaClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return OllamaClient(
            baseURL: URL(string: "http://ollama.test")!,
            model: model,
            session: session
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
