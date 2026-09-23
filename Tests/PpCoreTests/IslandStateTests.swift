import XCTest
@testable import PpCore

final class IslandStateTests: XCTestCase {
    func testIslandStateSizes() {
        XCTAssertEqual(IslandState.idle.size, CGSize(width: 220, height: 34))
        XCTAssertEqual(IslandState.listening.size, CGSize(width: 420, height: 64))
        XCTAssertEqual(IslandState.working.size, CGSize(width: 520, height: 96))
        XCTAssertEqual(IslandState.result(text: "Done").size, CGSize(width: 420, height: 64))
        XCTAssertEqual(IslandState.error(text: "Failed").size, CGSize(width: 480, height: 72))
    }

    func testIslandAutoHideDurations() {
        XCTAssertNil(IslandState.idle.autoHideDuration)
        XCTAssertNil(IslandState.listening.autoHideDuration)
        XCTAssertNil(IslandState.working.autoHideDuration, ".working must never auto-hide")
        XCTAssertEqual(IslandState.result(text: "Done").autoHideDuration, 2.5, ".result must auto-hide after 2.5s")
        XCTAssertEqual(IslandState.error(text: "Error").autoHideDuration, 6.0, ".error must auto-hide after 6.0s")
    }

    func testHonestRefusalsAreNotDressedAsResults() {
        // Anything pp could not do must reach the island as a problem, never as a green result.
        XCTAssertTrue(IslandState.reportsProblem("Command stopped"))
        XCTAssertTrue(IslandState.reportsProblem("Alarm not set"))
        XCTAssertTrue(IslandState.reportsProblem("Reminder not set"))
        XCTAssertTrue(IslandState.reportsProblem("A reminder needs a time"))
        XCTAssertTrue(IslandState.reportsProblem("Notification permission needed"))
        XCTAssertTrue(IslandState.reportsProblem("Could not verify timer schedule."))

        XCTAssertFalse(IslandState.reportsProblem("Alarm set for 7:30 PM."))
        XCTAssertFalse(IslandState.reportsProblem("Opened youtube.com in Zen"))
        XCTAssertFalse(IslandState.reportsProblem("No active alarms or timers."))
    }
}
