import XCTest
@testable import DrillSergeant

@MainActor
final class NotchTrayTests: XCTestCase {
    func testIdleTrayHidesAfterFiveSeconds() {
        let clock = TestClock()
        let controller = TrayController(clock: clock)

        XCTAssertTrue(controller.isExtended)
        clock.advance(by: 4.9)
        XCTAssertTrue(controller.isExtended)

        clock.advance(by: 0.1)
        XCTAssertFalse(controller.isExtended)
    }

    func testActiveStatesExtendImmediatelyAndCancelIdleTimer() {
        let clock = TestClock()
        let controller = TrayController(clock: clock)
        clock.advance(by: 5)

        for state in [CompanionState.watching, .angry, .happy] {
            controller.setState(state)
            XCTAssertTrue(controller.isExtended)
        }

        clock.advance(by: 10)
        XCTAssertTrue(controller.isExtended)
    }

    func testPinExtendsTrayAndUnpinRestartsIdleTimer() {
        let clock = TestClock()
        let controller = TrayController(clock: clock)
        clock.advance(by: 5)

        controller.setPinned(true)
        XCTAssertTrue(controller.isExtended)
        clock.advance(by: 20)
        XCTAssertTrue(controller.isExtended)

        controller.setPinned(false)
        clock.advance(by: 4.9)
        XCTAssertTrue(controller.isExtended)
        clock.advance(by: 0.1)
        XCTAssertFalse(controller.isExtended)
    }

    func testHoverExtendsTrayAndMouseExitRestartsIdleTimer() {
        let clock = TestClock()
        let controller = TrayController(clock: clock)
        clock.advance(by: 5)

        controller.setHovering(true)
        XCTAssertTrue(controller.isExtended)
        clock.advance(by: 20)
        XCTAssertTrue(controller.isExtended)

        controller.setHovering(false)
        clock.advance(by: 4.9)
        XCTAssertTrue(controller.isExtended)
        clock.advance(by: 0.1)
        XCTAssertFalse(controller.isExtended)
    }

    func testReturningToIdleStartsFreshTimer() {
        let clock = TestClock()
        let controller = TrayController(clock: clock, state: .watching)

        controller.setState(.idle)
        clock.advance(by: 4.9)
        XCTAssertTrue(controller.isExtended)

        controller.setState(.watching)
        controller.setState(.idle)
        clock.advance(by: 4.9)
        XCTAssertTrue(controller.isExtended)
        clock.advance(by: 0.1)
        XCTAssertFalse(controller.isExtended)
    }
}
