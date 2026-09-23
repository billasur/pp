import XCTest
@testable import PpCore

final class TimeIntentTests: XCTestCase {
    func testBareHourAlarmResolvesNextOccurrence() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!

        // 9 AM: "alarm for 7" resolves to 7:00 PM today
        let morning = cal.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 9, minute: 0))!
        let intent1 = TimeIntentParser.parse("alarm for 7", relativeTo: morning, calendar: cal)
        guard case .alarm(_, _, let formatted1) = intent1 else {
            XCTFail("Must parse as alarm")
            return
        }
        XCTAssertEqual(formatted1, "7:00 PM")

        // 5 AM: "alarm for 7" resolves to 7:00 AM today
        let early = cal.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 5, minute: 0))!
        let intent2 = TimeIntentParser.parse("alarm for 7", relativeTo: early, calendar: cal)
        guard case .alarm(_, _, let formatted2) = intent2 else {
            XCTFail("Must parse as alarm")
            return
        }
        XCTAssertEqual(formatted2, "7:00 AM")

        // 10 PM: "alarm for 7" resolves to 7:00 AM tomorrow
        let night = cal.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 22, minute: 0))!
        let intent3 = TimeIntentParser.parse("alarm for 7", relativeTo: night, calendar: cal)
        guard case .alarm(_, _, let formatted3) = intent3 else {
            XCTFail("Must parse as alarm")
            return
        }
        XCTAssertEqual(formatted3, "7:00 AM")
    }

    func testSpokenNumberWordsInAlarms() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let baseDate = cal.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 6, minute: 0))!

        let intent = TimeIntentParser.parse("set an alarm for seven thirty am", relativeTo: baseDate, calendar: cal)
        guard case .alarm(_, _, let formatted) = intent else {
            XCTFail("Must parse spoken time")
            return
        }
        XCTAssertEqual(formatted, "7:30 AM")
    }

    func testTimersAndNumberWords() {
        let timer1 = TimeIntentParser.parse("timer for 10 minutes")
        XCTAssertEqual(timer1, .timer(durationSeconds: 600, label: "10 minutes"))

        let timer2 = TimeIntentParser.parse("set a timer for thirty seconds")
        XCTAssertEqual(timer2, .timer(durationSeconds: 30, label: "30 seconds"))

        let timer3 = TimeIntentParser.parse("set timer for half an hour")
        XCTAssertEqual(timer3, .timer(durationSeconds: 1800, label: "30 minutes"))
    }

    func testParseNegativesNotTimers() {
        // Media navigation phrases must not be mistaken for timers
        let neg1 = TimeIntentParser.parse("skip forward 30 seconds")
        XCTAssertEqual(neg1, .none)

        let neg2 = TimeIntentParser.parse("fast forward 10 minutes")
        XCTAssertEqual(neg2, .none)

        let neg3 = TimeIntentParser.parse("rewind 15 seconds")
        XCTAssertEqual(neg3, .none)
    }

    func testCancelAndList() {
        let cancelAll = TimeIntentParser.parse("cancel alarm")
        XCTAssertEqual(cancelAll, .cancel(target: nil))

        let cancelAll2 = TimeIntentParser.parse("cancel all alarms")
        XCTAssertEqual(cancelAll2, .cancel(target: nil))

        let cancelMyAlarm = TimeIntentParser.parse("cancel my alarm")
        XCTAssertEqual(cancelMyAlarm, .cancel(target: nil))

        let cancelSpecific = TimeIntentParser.parse("cancel timer morning")
        XCTAssertEqual(cancelSpecific, .cancel(target: "morning"))

        let list = TimeIntentParser.parse("show my alarms")
        XCTAssertEqual(list, .list)

        let list2 = TimeIntentParser.parse("what alarms do i have")
        XCTAssertEqual(list2, .list)
    }

    func testStopRingingAndQuiet() {
        XCTAssertEqual(TimeIntentParser.parse("stop"), .stopRinging)
        XCTAssertEqual(TimeIntentParser.parse("stop the alarm"), .stopRinging)
        XCTAssertEqual(TimeIntentParser.parse("stop alarm"), .stopRinging)
        XCTAssertEqual(TimeIntentParser.parse("stop ringing"), .stopRinging)
        XCTAssertEqual(TimeIntentParser.parse("quiet the alarm"), .stopRinging)
        XCTAssertEqual(TimeIntentParser.parse("quiet"), .stopRinging)
        XCTAssertEqual(TimeIntentParser.parse("silence the alarm"), .stopRinging)
        XCTAssertEqual(TimeIntentParser.parse("dismiss alarm"), .stopRinging)
    }

    func testSnoozePhrases() {
        XCTAssertEqual(TimeIntentParser.parse("snooze"), .snooze(minutes: 9))
        XCTAssertEqual(TimeIntentParser.parse("snooze alarm"), .snooze(minutes: 9))
        XCTAssertEqual(TimeIntentParser.parse("snooze the alarm"), .snooze(minutes: 9))
        XCTAssertEqual(TimeIntentParser.parse("snooze for 5 minutes"), .snooze(minutes: 5))
        XCTAssertEqual(TimeIntentParser.parse("snooze for ten minutes"), .snooze(minutes: 10))
    }

    func testNextAlarmQueries() {
        XCTAssertEqual(TimeIntentParser.parse("what is my next alarm"), .nextAlarm)
        XCTAssertEqual(TimeIntentParser.parse("what's my next alarm"), .nextAlarm)
        XCTAssertEqual(TimeIntentParser.parse("when is my next alarm"), .nextAlarm)
        XCTAssertEqual(TimeIntentParser.parse("next alarm"), .nextAlarm)
    }

    func testTimerInAndFromNow() {
        let t1 = TimeIntentParser.parse("in twenty minutes")
        XCTAssertEqual(t1, .timer(durationSeconds: 1200, label: "20 minutes"))

        let t2 = TimeIntentParser.parse("in 20 minutes")
        XCTAssertEqual(t2, .timer(durationSeconds: 1200, label: "20 minutes"))

        let t3 = TimeIntentParser.parse("twenty minutes from now")
        XCTAssertEqual(t3, .timer(durationSeconds: 1200, label: "20 minutes"))

        let t4 = TimeIntentParser.parse("15 seconds from now")
        XCTAssertEqual(t4, .timer(durationSeconds: 15, label: "15 seconds"))
    }

    func testAlarmAtAndTomorrow() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let baseDate = cal.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 10, minute: 0))!

        let a1 = TimeIntentParser.parse("at 7", relativeTo: baseDate, calendar: cal)
        guard case .alarm(_, _, let fmt1) = a1 else {
            XCTFail("Expected alarm for 'at 7'")
            return
        }
        XCTAssertEqual(fmt1, "7:00 PM")

        let a2 = TimeIntentParser.parse("wake me at 6:30", relativeTo: baseDate, calendar: cal)
        guard case .alarm(_, _, let fmt2) = a2 else {
            XCTFail("Expected alarm for 'wake me at 6:30'")
            return
        }
        XCTAssertEqual(fmt2, "6:30 PM")

        let a3 = TimeIntentParser.parse("tomorrow at 7", relativeTo: baseDate, calendar: cal)
        guard case .alarm(let d3, _, let fmt3) = a3 else {
            XCTFail("Expected alarm for 'tomorrow at 7'")
            return
        }
        XCTAssertEqual(fmt3, "7:00 PM")
        let day3 = cal.component(.day, from: d3)
        XCTAssertEqual(day3, 24)

        let a4 = TimeIntentParser.parse("tomorrow at 7:15 am", relativeTo: baseDate, calendar: cal)
        guard case .alarm(let d4, _, let fmt4) = a4 else {
            XCTFail("Expected alarm for 'tomorrow at 7:15 am'")
            return
        }
        XCTAssertEqual(fmt4, "7:15 AM")
        let day4 = cal.component(.day, from: d4)
        XCTAssertEqual(day4, 24)
    }

    func testDigitsWithoutColon() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let baseDate = cal.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 5, minute: 0))!

        let a1 = TimeIntentParser.parse("alarm 715 am", relativeTo: baseDate, calendar: cal)
        guard case .alarm(_, _, let fmt1) = a1 else {
            XCTFail("Expected alarm for 'alarm 715 am'")
            return
        }
        XCTAssertEqual(fmt1, "7:15 AM")

        let a2 = TimeIntentParser.parse("alarm for 7 15 am", relativeTo: baseDate, calendar: cal)
        guard case .alarm(_, _, let fmt2) = a2 else {
            XCTFail("Expected alarm for 'alarm for 7 15 am'")
            return
        }
        XCTAssertEqual(fmt2, "7:15 AM")
    }

    func testReminderWithoutATimeIsReportedAsSuch() {
        let intent = TimeIntentParser.parse("remind me to call mom")
        guard case .remind(let text, let date) = intent else {
            XCTFail("Must parse as a reminder")
            return
        }
        XCTAssertEqual(text, "call mom")
        XCTAssertNil(date, "A reminder with no spoken time has nothing to schedule")
    }

    func testReminderTakesTheTrailingTime() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let base = cal.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 9, minute: 0))!

        let intent = TimeIntentParser.parse("remind me to take medicine at 5pm", relativeTo: base, calendar: cal)
        guard case .remind(let text, let date) = intent, let date else {
            XCTFail("Must parse as a reminder with a time")
            return
        }
        XCTAssertEqual(text, "take medicine")
        XCTAssertEqual(cal.component(.hour, from: date), 17)
    }

    func testReminderWithTheTimeFirst() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let base = cal.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 9, minute: 0))!

        let intent = TimeIntentParser.parse("remind me at 7 to water the plants", relativeTo: base, calendar: cal)
        guard case .remind(let text, let date) = intent, let date else {
            XCTFail("Must parse as a reminder with a time")
            return
        }
        XCTAssertEqual(text, "water the plants")
        XCTAssertEqual(cal.component(.hour, from: date), 19)
    }
}
