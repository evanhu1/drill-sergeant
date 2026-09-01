import XCTest
@testable import DrillSergeant

@MainActor
final class CoordinatorSmokeTests: XCTestCase {
    func testCoordinatorCanBeConstructedWithoutCreatingWindows() {
        _ = AppCoordinator()
    }
}
