import Foundation

public enum TimeIntent: Equatable, Sendable {
    case alarm(date: Date, label: String, formattedTime: String)
    case timer(durationSeconds: TimeInterval, label: String)
    case remind(text: String, date: Date?)
    case list
    case cancel(target: String?)
    case stopRinging
    case snooze(minutes: Int)
    case nextAlarm
    case none

    public var isActionable: Bool {
        self != .none
    }
}

public enum TimeIntentParser {
    /// Parses an utterance into a TimeIntent.
    /// Handles bare hours (e.g. "alarm for 7") resolving to the next occurrence with AM/PM stated.
    /// Distinguishes media negatives ("skip forward 30 seconds" is NOT a timer).
    public static func parse(_ utterance: String, relativeTo now: Date = Date(), calendar: Calendar = .current) -> TimeIntent {
        let clean = utterance.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // Negative check: media transport commands are NOT timers
        let mediaNegatives = ["skip forward", "skip back", "fast forward", "rewind", "jump forward", "jump back"]
        for neg in mediaNegatives {
            if clean.contains(neg) { return .none }
        }

        // Ringer control (while alarm is ringing)
        if clean == "stop" || clean == "stop the alarm" || clean == "stop alarm" || clean == "stop ringing" ||
           clean == "quiet" || clean == "quiet the alarm" || clean == "quiet alarm" ||
           clean == "silence" || clean == "silence the alarm" || clean == "silence alarm" ||
           clean == "dismiss alarm" || clean == "dismiss the alarm" {
            return .stopRinging
        }

        // Snooze
        if clean == "snooze" || clean == "snooze alarm" || clean == "snooze the alarm" {
            return .snooze(minutes: 9)
        }
        if clean.hasPrefix("snooze for ") {
            let durPart = String(clean.dropFirst(11)).trimmingCharacters(in: .whitespaces)
            let words = durPart.split(separator: " ").map(String.init)
            if let first = words.first, let mins = NumberWords.parseInteger(first) {
                return .snooze(minutes: mins)
            }
            return .snooze(minutes: 9)
        }

        // Next alarm query
        if clean == "what is my next alarm" || clean == "what's my next alarm" ||
           clean == "when is my next alarm" || clean == "next alarm" {
            return .nextAlarm
        }

        // List alarms/timers
        if clean == "list alarms" || clean == "show alarms" || clean == "show my alarms" || clean == "what alarms do i have" ||
           clean == "list timers" || clean == "show timers" || clean == "alarms" || clean == "timers" {
            return .list
        }

        // Cancel
        if clean == "cancel my alarm" || clean == "cancel my alarms" || clean == "cancel all alarms" || clean == "cancel alarms" {
            return .cancel(target: nil)
        }
        if clean.hasPrefix("cancel alarm") || clean.hasPrefix("delete alarm") || clean.hasPrefix("stop alarm") {
            let rest = clean.replacingOccurrences(of: "cancel alarm", with: "")
                .replacingOccurrences(of: "delete alarm", with: "")
                .replacingOccurrences(of: "stop alarm", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .cancel(target: rest.isEmpty ? nil : rest)
        }
        if clean.hasPrefix("cancel timer") || clean.hasPrefix("stop timer") {
            let rest = clean.replacingOccurrences(of: "cancel timer", with: "")
                .replacingOccurrences(of: "stop timer", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .cancel(target: rest.isEmpty ? nil : rest)
        }

        // Remind: "remind me to call Mom", "remind me to take medicine at 5pm",
        // "remind me at 7 to water the plants". A reminder with no time is reported as such
        // rather than stored and forgotten.
        if clean.hasPrefix("remind me to ") || clean.hasPrefix("remind me ") {
            var body = clean.hasPrefix("remind me to ") ? String(clean.dropFirst(13)) : String(clean.dropFirst(10))
            var time: Date?

            // "remind me to take medicine at 5pm" — time trails the thing being remembered.
            if let range = body.range(of: " at ", options: .backwards) {
                let spokenTime = String(body[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if case .alarm(let date, _, _)? = parseAlarm("at " + spokenTime, relativeTo: now, calendar: calendar) {
                    time = date
                    body = String(body[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                }
            }

            // "remind me at 7 to water the plants" — time first, the thing after " to ".
            if time == nil, body.hasPrefix("at "), let toRange = body.range(of: " to ") {
                let spokenTime = String(body[body.index(body.startIndex, offsetBy: 3)..<toRange.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                if case .alarm(let date, _, _)? = parseAlarm("at " + spokenTime, relativeTo: now, calendar: calendar) {
                    time = date
                    body = String(body[toRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                }
            }

            return .remind(text: body, date: time)
        }

        // Timer: "timer for 10 minutes", "set a timer for 5 mins", "in twenty minutes", "twenty minutes from now"
        if let timerIntent = parseTimer(clean) {
            return timerIntent
        }

        // Alarm: "alarm for 7", "set alarm for 7:15", "tomorrow at 7", "at 7", "wake me at 6:30"
        if let alarmIntent = parseAlarm(clean, relativeTo: now, calendar: calendar) {
            return alarmIntent
        }

        return .none
    }

    private static func parseTimer(_ clean: String) -> TimeIntent? {
        let prefixes = [
            "set a timer for ", "set timer for ", "timer for ",
            "timer ", "in "
        ]
        var durStr: String?
        for p in prefixes {
            if clean.hasPrefix(p) {
                durStr = String(clean.dropFirst(p.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        if durStr == nil && clean.hasSuffix(" from now") {
            durStr = String(clean.dropLast(9)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let rawDur = durStr, !rawDur.isEmpty else { return nil }

        // Parse duration: e.g. "10 minutes", "5 mins", "30 seconds", "1 hour", "ten minutes", "twenty minutes", "half an hour"
        if rawDur == "half an hour" || rawDur == "half hour" {
            return .timer(durationSeconds: 1800, label: "30 minutes")
        }
        if rawDur == "an hour" || rawDur == "one hour" {
            return .timer(durationSeconds: 3600, label: "1 hour")
        }

        let words = rawDur.split(separator: " ").map(String.init)
        guard words.count >= 2 else { return nil }

        guard let amount = NumberWords.parseInteger(words[0]) else { return nil }
        let unit = words[1].lowercased()

        if unit.hasPrefix("sec") {
            return .timer(durationSeconds: TimeInterval(amount), label: "\(amount) seconds")
        } else if unit.hasPrefix("min") {
            return .timer(durationSeconds: TimeInterval(amount * 60), label: "\(amount) minutes")
        } else if unit.hasPrefix("hour") || unit.hasPrefix("hr") {
            return .timer(durationSeconds: TimeInterval(amount * 3600), label: "\(amount) hours")
        }

        return nil
    }

    private static func parseAlarm(_ clean: String, relativeTo now: Date, calendar: Calendar) -> TimeIntent? {
        var isTomorrow = false
        var working = clean
        if working.hasPrefix("tomorrow at ") {
            isTomorrow = true
            working = String(working.dropFirst(12)).trimmingCharacters(in: .whitespaces)
        } else if working.hasPrefix("tomorrow ") {
            isTomorrow = true
            working = String(working.dropFirst(9)).trimmingCharacters(in: .whitespaces)
        }

        let prefixes = [
            "set alarm for ", "set an alarm for ", "alarm for ",
            "set alarm at ", "alarm at ", "wake me at ", "wake me up at ",
            "alarm ", "at "
        ]
        var timeStr: String?
        for p in prefixes {
            if working.hasPrefix(p) {
                timeStr = String(working.dropFirst(p.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        if timeStr == nil && isTomorrow {
            timeStr = working
        }
        guard let rawTime = timeStr, !rawTime.isEmpty else { return nil }

        var targetTime = rawTime
            .replacingOccurrences(of: " o'clock", with: "")
            .replacingOccurrences(of: " oclock", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var explicitAM = targetTime.hasSuffix("am") || targetTime.hasSuffix(" a.m.")
        var explicitPM = targetTime.hasSuffix("pm") || targetTime.hasSuffix(" p.m.")
        if explicitAM {
            targetTime = targetTime.replacingOccurrences(of: " a.m.", with: "").replacingOccurrences(of: "am", with: "").trimmingCharacters(in: .whitespaces)
        }
        if explicitPM {
            targetTime = targetTime.replacingOccurrences(of: " p.m.", with: "").replacingOccurrences(of: "pm", with: "").trimmingCharacters(in: .whitespaces)
        }

        guard let parsed = NumberWords.parseSpokenTime(targetTime) else { return nil }
        let rawHour = parsed.hour
        let minute = parsed.minute

        guard rawHour >= 1 && rawHour <= 24, minute >= 0 && minute < 60 else { return nil }

        let currentHour = calendar.component(.hour, from: now)
        let currentMinute = calendar.component(.minute, from: now)

        var finalHour = rawHour
        var isPM = explicitPM

        if !explicitAM && !explicitPM {
            // Bare hour rule: resolve next occurrence
            if rawHour <= 12 {
                let currentTotalMin = currentHour * 60 + currentMinute
                let amTotalMin = rawHour * 60 + minute
                let pmTotalMin = (rawHour + 12) * 60 + minute

                if currentTotalMin < amTotalMin {
                    finalHour = rawHour
                    isPM = false
                } else if currentTotalMin < pmTotalMin {
                    finalHour = rawHour + 12
                    isPM = true
                } else {
                    // Next day AM
                    finalHour = rawHour
                    isPM = false
                }
            }
        } else if explicitPM && rawHour < 12 {
            finalHour = rawHour + 12
        } else if explicitAM && rawHour == 12 {
            finalHour = 0
        }

        var baseDate = now
        if isTomorrow {
            // Advance by 1 day so nextDate matching lands on tomorrow
            if let tomorrowDate = calendar.date(byAdding: .day, value: 1, to: now) {
                // Set baseDate to start of tomorrow minus 1 second
                baseDate = calendar.startOfDay(for: tomorrowDate)
            }
        }

        // Calculate next target date DST-safe via matching DateComponents
        var matchComponents = DateComponents()
        matchComponents.hour = finalHour
        matchComponents.minute = minute
        matchComponents.second = 0

        guard let nextDate = calendar.nextDate(after: baseDate, matching: matchComponents, matchingPolicy: .nextTime) else {
            return nil
        }

        let displayHour = (finalHour % 12 == 0) ? 12 : (finalHour % 12)
        let displayPeriod = (finalHour >= 12) ? "PM" : "AM"
        let formatted = String(format: "%d:%02d %@", displayHour, minute, displayPeriod)

        return .alarm(date: nextDate, label: "Alarm", formattedTime: formatted)
    }
}
