import XCTest
@testable import DrillSergeant

final class ModelPullTests: XCTestCase {
    override func tearDown() {
        PullMockURLProtocol.lines = nil
        PullMockURLProtocol.statusCode = 200
        super.tearDown()
    }

    func testPullReportsEveryProgressLineAndFinishes() async throws {
        PullMockURLProtocol.lines = [
            #"{"status":"pulling manifest"}"#,
            #"{"status":"pulling aabb","total":6000000000,"completed":1500000000}"#,
            #"{"status":"pulling aabb","total":6000000000,"completed":6000000000}"#,
            #"{"status":"success"}"#,
        ]
        let client = makeClient()
        let recorder = ProgressRecorder()

        try await client.pullModel { recorder.record($0) }

        let progress = recorder.all
        XCTAssertEqual(progress.count, 4)
        XCTAssertEqual(progress[0].status, "pulling manifest")
        XCTAssertNil(progress[0].fraction)
        XCTAssertEqual(progress[1].fraction ?? 0, 0.25, accuracy: 0.001)
        XCTAssertEqual(progress[1].sizeSummary, "1.4 of 5.6 GB")
        XCTAssertEqual(progress[3].status, "success")
    }

    func testPullSurfacesAStreamedError() async {
        PullMockURLProtocol.lines = [
            #"{"status":"pulling manifest"}"#,
            #"{"error":"model 'nope' not found"}"#,
        ]
        let client = makeClient()

        do {
            try await client.pullModel { _ in }
            XCTFail("Expected the streamed error to be thrown")
        } catch let error as OllamaError {
            XCTAssertEqual(error, .badResponse("model 'nope' not found"))
        } catch {
            XCTFail("Expected an OllamaError, got \(error)")
        }
    }

    /// A stream that stops early leaves a half-downloaded model, so it must not read as done.
    func testPullFailsWhenTheStreamEndsBeforeSuccess() async {
        PullMockURLProtocol.lines = [
            #"{"status":"pulling aabb","total":6000000000,"completed":900000}"#,
        ]
        let client = makeClient()

        do {
            try await client.pullModel { _ in }
            XCTFail("Expected a truncated stream to throw")
        } catch let error as OllamaError {
            XCTAssertEqual(error, .badResponse("Model download ended before it finished"))
        } catch {
            XCTFail("Expected an OllamaError, got \(error)")
        }
    }

    func testPullReportsHTTPFailures() async {
        PullMockURLProtocol.lines = [""]
        PullMockURLProtocol.statusCode = 500
        let client = makeClient()

        do {
            try await client.pullModel { _ in }
            XCTFail("Expected an HTTP failure to throw")
        } catch let error as OllamaError {
            XCTAssertEqual(error, .http(500))
        } catch {
            XCTFail("Expected an OllamaError, got \(error)")
        }
    }

    private func makeClient() -> OllamaClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PullMockURLProtocol.self]
        return OllamaClient(
            baseURL: URL(string: "http://127.0.0.1:11434")!,
            model: "qwen3-vl:8b",
            session: URLSession(configuration: configuration)
        )
    }
}

@MainActor
final class ModelReadinessStateTests: XCTestCase {
    func testDownloadProgressIsClampedAndFormatted() {
        let progress = ModelDownloadProgress(
            status: "pulling",
            completed: 3_221_225_472,
            total: 6_442_450_944
        )

        XCTAssertEqual(progress.fraction ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(progress.sizeSummary, "3.0 of 6.0 GB")
    }

    func testProgressWithoutATotalHasNoFraction() {
        let progress = ModelDownloadProgress(status: "pulling manifest", completed: 0, total: 0)

        XCTAssertNil(progress.fraction)
        XCTAssertNil(progress.sizeSummary)
    }

    func testReadyIsTheOnlyReadyState() {
        XCTAssertTrue(ModelReadinessState.ready.isReady)
        XCTAssertFalse(ModelReadinessState.waitingForOllama.isReady)
        XCTAssertFalse(ModelReadinessState.downloading(fraction: 1, detail: nil).isReady)
        XCTAssertFalse(ModelReadinessState.retrying(reason: "x").isReady)
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ModelDownloadProgress] = []

    var all: [ModelDownloadProgress] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ progress: ModelDownloadProgress) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(progress)
    }
}

/// Answers with newline-delimited JSON, the way Ollama streams `/api/pull`.
private final class PullMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var lines: [String]?
    nonisolated(unsafe) static var statusCode = 200

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/x-ndjson"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for line in Self.lines ?? [] {
            client?.urlProtocol(self, didLoad: Data("\(line)\n".utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class DownloadProgressTrackerTests: XCTestCase {
    /// The tiny manifest layers Ollama reports first must not drive the number.
    func testTheLargestLayerIsTheOneReported() {
        let tracker = DownloadProgressTracker()

        _ = tracker.scaleIfPercentChanged(progress(completed: 100, total: 1_000))
        let model = tracker.scaleIfPercentChanged(progress(completed: 0, total: 6_000_000_000))
        let half = tracker.scaleIfPercentChanged(
            progress(completed: 3_000_000_000, total: 6_000_000_000)
        )
        // A later small layer must not drag the reading backwards.
        let afterSmallLayer = tracker.scaleIfPercentChanged(progress(completed: 5, total: 1_000))

        XCTAssertEqual(model?.total, 6_000_000_000)
        XCTAssertEqual(half?.fraction ?? 0, 0.5, accuracy: 0.001)
        XCTAssertNil(afterSmallLayer)
    }

    func testProgressNeverGoesBackwardsWithinALayer() {
        let tracker = DownloadProgressTracker()
        _ = tracker.scaleIfPercentChanged(progress(completed: 6_000_000, total: 10_000_000))

        let backwards = tracker.scaleIfPercentChanged(
            progress(completed: 1_000_000, total: 10_000_000)
        )

        XCTAssertNil(backwards, "A late out-of-order line must not lower the percentage")
    }

    /// Ollama streams many lines per percent; only the ones that move it are worth showing.
    func testRepeatedLinesInsideOnePercentAreDropped() {
        let tracker = DownloadProgressTracker()
        XCTAssertNotNil(tracker.scaleIfPercentChanged(progress(completed: 100, total: 10_000)))

        XCTAssertNil(tracker.scaleIfPercentChanged(progress(completed: 101, total: 10_000)))
        XCTAssertNil(tracker.scaleIfPercentChanged(progress(completed: 104, total: 10_000)))
        XCTAssertNotNil(tracker.scaleIfPercentChanged(progress(completed: 160, total: 10_000)))
    }

    private func progress(completed: Int64, total: Int64) -> ModelDownloadProgress {
        ModelDownloadProgress(status: "pulling", completed: completed, total: total)
    }
}
