import XCTest
@testable import DrillSergeant

final class ActiveWindowInfoTests: XCTestCase {
    func testSummaryIncludesQuotedTitle() {
        let info = ActiveWindowInfo(
            appName: "Google Chrome",
            bundleID: "com.google.Chrome",
            windowTitle: "Project docs"
        )
        XCTAssertEqual(info.summary, "Google Chrome — “Project docs”")
    }

    func testSummaryWithoutTitleUsesAppName() {
        let info = ActiveWindowInfo(appName: "Terminal", bundleID: nil, windowTitle: nil)
        XCTAssertEqual(info.summary, "Terminal")
    }

    func testLooksLikeYouTubeFromTitleCaseInsensitively() {
        let info = ActiveWindowInfo(
            appName: "Chrome",
            bundleID: "com.google.Chrome",
            windowTitle: "YOUTUBE — video"
        )
        XCTAssertTrue(info.looksLikeYouTube)
    }

    func testLooksLikeYouTubeFromBundleCaseInsensitively() {
        let info = ActiveWindowInfo(
            appName: "Viewer",
            bundleID: "com.example.YouTubeViewer",
            windowTitle: nil
        )
        XCTAssertTrue(info.looksLikeYouTube)
    }

    func testUnrelatedWindowIsNotYouTube() {
        let info = ActiveWindowInfo(
            appName: "Xcode",
            bundleID: "com.apple.dt.Xcode",
            windowTitle: "DrillSergeant"
        )
        XCTAssertFalse(info.looksLikeYouTube)
    }
}
