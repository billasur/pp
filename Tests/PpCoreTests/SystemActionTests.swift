import XCTest
@testable import PpCore

final class SystemActionTests: XCTestCase {
    func testBareHourAlarmResolvesNextOccurrenceAndStatesPeriod() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        // Case 1: morning 05:00, "alarm for 7" -> 7:00 AM
        let morning = calendar.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 5, minute: 0))!
        let action1 = SystemActionParser.parse("alarm for 7", relativeTo: morning, calendar: calendar)
        XCTAssertNotNil(action1)
        XCTAssertEqual(action1?.kind, .setAlarm)
        XCTAssertEqual(action1?.value, "7:00 AM")
        XCTAssertTrue(action1?.confirmationMessage.contains("7:00 AM") == true)

        // Case 2: mid-day 11:00, "alarm for 7" -> 7:00 PM
        let midday = calendar.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 11, minute: 0))!
        let action2 = SystemActionParser.parse("alarm for 7", relativeTo: midday, calendar: calendar)
        XCTAssertNotNil(action2)
        XCTAssertEqual(action2?.kind, .setAlarm)
        XCTAssertEqual(action2?.value, "7:00 PM")
        XCTAssertTrue(action2?.confirmationMessage.contains("7:00 PM") == true)

        // Case 3: late night 22:00 (10 PM), "alarm for 7" -> 7:00 AM next day
        let night = calendar.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 22, minute: 0))!
        let action3 = SystemActionParser.parse("set alarm for 7", relativeTo: night, calendar: calendar)
        XCTAssertNotNil(action3)
        XCTAssertEqual(action3?.kind, .setAlarm)
        XCTAssertEqual(action3?.value, "7:00 AM")
        XCTAssertTrue(action3?.confirmationMessage.contains("7:00 AM") == true)
    }

    func testTimers() {
        let action = SystemActionParser.parse("set timer for 10 minutes")
        XCTAssertEqual(action?.kind, .setTimer)
        XCTAssertEqual(action?.value, "10 minutes")
        XCTAssertEqual(action?.confirmationMessage, "Timer set for 10 minutes.")
    }

    func testVolume() {
        let vol = SystemActionParser.parse("set volume to 80%")
        XCTAssertEqual(vol?.kind, .setVolume)
        XCTAssertEqual(vol?.value, "80")

        let mute = SystemActionParser.parse("mute")
        XCTAssertEqual(mute?.kind, .setVolume)
        XCTAssertEqual(mute?.value, "0")
    }

    func testDarkMode() {
        let dark = SystemActionParser.parse("turn on dark mode")
        XCTAssertEqual(dark?.kind, .setDarkMode)
        XCTAssertEqual(dark?.value, "true")

        let light = SystemActionParser.parse("light mode")
        XCTAssertEqual(light?.kind, .setDarkMode)
        XCTAssertEqual(light?.value, "false")
    }

    func testLockAndScreenshot() {
        let lock = SystemActionParser.parse("lock screen")
        XCTAssertEqual(lock?.kind, .lockScreen)

        let shot = SystemActionParser.parse("take screenshot")
        XCTAssertEqual(shot?.kind, .takeScreenshot)
    }
}
