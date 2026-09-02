import XCTest
@testable import DrillSergeant

final class CursorTrackerTests: XCTestCase {
    func testAppliesPowerCurvePerAxis() {
        let gaze = GazeMapper.map(
            mouseLocation: CGPoint(x: 250, y: 375),
            panelCenter: CGPoint(x: 500, y: 500),
            screenSize: CGSize(width: 2_000, height: 1_000)
        )

        XCTAssertEqual(gaze.x, -pow(0.25, 0.55), accuracy: 0.000_001)
        XCTAssertEqual(gaze.y, pow(0.25, 0.55), accuracy: 0.000_001)
    }

    func testClampsBeforeApplyingPowerCurve() {
        let gaze = GazeMapper.map(
            mouseLocation: CGPoint(x: 5_000, y: -5_000),
            panelCenter: .zero,
            screenSize: CGSize(width: 1_000, height: 1_000)
        )

        XCTAssertEqual(gaze, CGPoint(x: 1, y: 1))
    }

    func testFlipsScreenYSoCursorBelowLooksDown() {
        let gaze = GazeMapper.map(
            mouseLocation: CGPoint(x: 500, y: 250),
            panelCenter: CGPoint(x: 500, y: 500),
            screenSize: CGSize(width: 1_000, height: 1_000)
        )

        XCTAssertEqual(gaze.x, 0)
        XCTAssertGreaterThan(gaze.y, 0)
    }
}
