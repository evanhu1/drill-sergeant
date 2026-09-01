import AppKit
import XCTest
@testable import DrillSergeant

final class NotchGeometryTests: XCTestCase {
    func testSyntheticFallbackDimensionsAndPosition() {
        let geometry = NotchGeometry.synthetic(
            screenFrame: CGRect(x: 100, y: 50, width: 1_440, height: 900)
        )

        XCTAssertFalse(geometry.hasPhysicalNotch)
        XCTAssertEqual(geometry.notchRect.width, 200)
        XCTAssertEqual(geometry.notchRect.height, 32)
        XCTAssertEqual(geometry.notchRect.midX, 820)
        XCTAssertEqual(geometry.notchRect.maxY, 950)
    }

    func testPanelFrameCoversNotchAndHangsBelowIt() {
        let geometry = NotchGeometry(
            screenFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
            notchRect: CGRect(x: 400, y: 768, width: 200, height: 32),
            hasPhysicalNotch: false
        )

        XCTAssertEqual(
            geometry.panelFrame(panelHeight: 34),
            CGRect(x: 400, y: 734, width: 200, height: 66)
        )
    }
}
