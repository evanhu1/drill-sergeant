import XCTest
@testable import DrillSergeant

final class ScreenCaptureTests: XCTestCase {
    func testScaledSizeLimitsLandscapeLongestEdge() {
        let size = ScreenCapture.scaledSize(width: 2_560, height: 1_600)
        XCTAssertEqual(size.width, 1_280)
        XCTAssertEqual(size.height, 800)
    }

    func testScaledSizeLimitsPortraitLongestEdge() {
        let size = ScreenCapture.scaledSize(width: 1_000, height: 2_000)
        XCTAssertEqual(size.width, 640)
        XCTAssertEqual(size.height, 1_280)
    }

    func testScaledSizeDoesNotUpscale() {
        let size = ScreenCapture.scaledSize(width: 800, height: 600)
        XCTAssertEqual(size.width, 800)
        XCTAssertEqual(size.height, 600)
    }

    func testScaledSizeUsesWindowDimensions() {
        let size = ScreenCapture.scaledSize(width: 1_512, height: 982)
        XCTAssertEqual(size.width, 1_280)
        XCTAssertEqual(size.height, 831)
    }

    func testScreenshotBase64() {
        let screenshot = Screenshot(
            jpegData: Data([0, 1, 2]),
            width: 1,
            height: 1,
            capturedAt: Date(),
            source: .window("Safari")
        )
        XCTAssertEqual(screenshot.base64, "AAEC")
        XCTAssertEqual(screenshot.source, .window("Safari"))
    }
}
