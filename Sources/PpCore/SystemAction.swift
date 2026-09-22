import Foundation
import AppKit

public enum SystemActionKind: String, Codable, CaseIterable, Sendable {
    case setAlarm = "set_alarm"
    case setTimer = "set_timer"
    case setVolume = "set_volume"
    case setDarkMode = "set_dark_mode"
    case lockScreen = "lock_screen"
    case takeScreenshot = "take_screenshot"
}

public struct SystemAction: Equatable, Sendable {
    public let kind: SystemActionKind
    public let value: String?
    public let confirmationMessage: String

    public init(kind: SystemActionKind, value: String?, confirmationMessage: String) {
        self.kind = kind
        self.value = value
        self.confirmationMessage = confirmationMessage
    }
}

public enum SystemActionParser {
    /// Bare-hour rule:
    /// "alarm for 7" resolves to next occurrence (e.g. 7:00 PM if currently morning and past 7am, or 7:00 AM next day)
    /// and the confirmation message states whether it's AM or PM.
    public static func parse(_ utterance: String, relativeTo now: Date = Date(), calendar: Calendar = .current) -> SystemAction? {
        let lower = utterance.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // 1. Alarm: "set alarm for 7", "alarm for 7", "set an alarm for 7:30 am", "alarm 7pm"
        if let alarmAction = parseAlarm(lower, relativeTo: now, calendar: calendar) {
            return alarmAction
        }

        // 2. Timer: "set timer for 10 minutes", "timer 5 mins", "set a timer for 1 hour"
        if let timerAction = parseTimer(lower) {
            return timerAction
        }

        // 3. Volume: "volume 50%", "mute volume", "set volume to 80", "unmute"
        if let volumeAction = parseVolume(lower) {
            return volumeAction
        }

        // 4. Dark mode: "turn on dark mode", "dark mode off", "enable dark mode", "light mode"
        if let darkModeAction = parseDarkMode(lower) {
            return darkModeAction
        }

        // 5. Lock screen: "lock screen", "lock mac", "lock the screen", "lock computer"
        if lower == "lock screen" || lower == "lock the screen" || lower == "lock mac" || lower == "lock my mac" || lower == "lock computer" {
            return SystemAction(kind: .lockScreen, value: nil, confirmationMessage: "Locking screen…")
        }

        // 6. Screenshot: "take screenshot", "screenshot", "take a screenshot", "capture screen"
        if lower == "take screenshot" || lower == "take a screenshot" || lower == "screenshot" || lower == "capture screen" {
            return SystemAction(kind: .takeScreenshot, value: nil, confirmationMessage: "Screenshot taken.")
        }

        return nil
    }

    private static func parseAlarm(_ lower: String, relativeTo now: Date, calendar: Calendar) -> SystemAction? {
        let prefixes = ["set alarm for ", "set an alarm for ", "alarm for ", "alarm at ", "set alarm at "]
        var timeStr: String?
        for p in prefixes {
            if lower.hasPrefix(p) {
                timeStr = String(lower.dropFirst(p.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        if timeStr == nil && lower.hasPrefix("alarm ") {
            timeStr = String(lower.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let rawTime = timeStr, !rawTime.isEmpty else { return nil }

        // Clean time string
        let cleanTime = rawTime.replacingOccurrences(of: " o'clock", with: "")
            .replacingOccurrences(of: " oclock", with: "")

        let currentHour = calendar.component(.hour, from: now)

        // Check bare hour (e.g. "7", "8", "11")
        if let bareHour = Int(cleanTime), bareHour >= 1, bareHour <= 12 {
            // Determine next occurrence: AM or PM
            var isPM = false
            var targetHour = bareHour

            // If bare hour is 7, could be 7 (07:00) or 19 (19:00)
            if currentHour < bareHour {
                // e.g. currently 5:00, 7 means 7:00 AM today
                targetHour = bareHour
                isPM = false
            } else if currentHour < bareHour + 12 {
                // e.g. currently 9:00, 7 means 7:00 PM today (19:00)
                targetHour = bareHour + 12
                isPM = true
            } else {
                // past both 7am and 7pm, next is 7:00 AM tomorrow
                targetHour = bareHour
                isPM = false
            }

            let period = isPM ? "PM" : "AM"
            _ = targetHour
            let formattedValue = String(format: "%d:00 %@", bareHour, period)
            let confirm = "Alarm set for \(bareHour):00 \(period)."
            return SystemAction(kind: .setAlarm, value: formattedValue, confirmationMessage: confirm)
        }

        // Check explicit AM/PM or HH:MM
        if cleanTime.contains("am") || cleanTime.contains("pm") || cleanTime.contains(":") {
            let confirm = "Alarm set for \(cleanTime)."
            return SystemAction(kind: .setAlarm, value: cleanTime, confirmationMessage: confirm)
        }

        return nil
    }

    private static func parseTimer(_ lower: String) -> SystemAction? {
        let prefixes = ["set timer for ", "set a timer for ", "timer for "]
        var durStr: String?
        for p in prefixes {
            if lower.hasPrefix(p) {
                durStr = String(lower.dropFirst(p.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        if durStr == nil && lower.hasPrefix("timer ") {
            durStr = String(lower.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let rawDur = durStr, !rawDur.isEmpty else { return nil }

        // e.g. "10 minutes", "5 mins", "1 hour", "30 seconds"
        return SystemAction(kind: .setTimer, value: rawDur, confirmationMessage: "Timer set for \(rawDur).")
    }

    private static func parseVolume(_ lower: String) -> SystemAction? {
        if lower == "mute" || lower == "mute volume" || lower == "volume mute" {
            return SystemAction(kind: .setVolume, value: "0", confirmationMessage: "Volume muted.")
        }
        if lower == "unmute" || lower == "unmute volume" {
            return SystemAction(kind: .setVolume, value: "50", confirmationMessage: "Volume unmuted.")
        }
        let prefixes = ["set volume to ", "volume to ", "volume "]
        for p in prefixes {
            if lower.hasPrefix(p) {
                let valStr = String(lower.dropFirst(p.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "%", with: "")
                if let vol = Int(valStr), vol >= 0, vol <= 100 {
                    return SystemAction(kind: .setVolume, value: "\(vol)", confirmationMessage: "Volume set to \(vol)%.")
                }
            }
        }
        return nil
    }

    private static func parseDarkMode(_ lower: String) -> SystemAction? {
        if lower == "turn on dark mode" || lower == "enable dark mode" || lower == "dark mode on" || lower == "dark mode" {
            return SystemAction(kind: .setDarkMode, value: "true", confirmationMessage: "Dark mode turned on.")
        }
        if lower == "turn off dark mode" || lower == "disable dark mode" || lower == "dark mode off" || lower == "light mode" || lower == "turn on light mode" {
            return SystemAction(kind: .setDarkMode, value: "false", confirmationMessage: "Dark mode turned off.")
        }
        return nil
    }
}
