import Foundation

/// Maps English number and fraction words to numeric values.
public enum NumberWords {
    private static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19
    ]

    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90
    ]

    /// Converts a word or compound word (e.g. "fifty", "twenty-five", "seven") to an integer if recognized.
    public static func parseInteger(_ word: String) -> Int? {
        let clean = word.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let direct = Int(clean) { return direct }
        if let val = units[clean] { return val }
        if let val = tens[clean] { return val }

        let parts = clean.split(separator: "-").map(String.init)
        if parts.count == 2, let t = tens[parts[0]], let u = units[parts[1]] {
            return t + u
        }
        let spaceParts = clean.split(separator: " ").map(String.init)
        if spaceParts.count == 2, let t = tens[spaceParts[0]], let u = units[spaceParts[1]] {
            return t + u
        }
        return nil
    }

    /// Converts phrases like "fifty", "a quarter", "half", "ten percent" to a percentage (0–100).
    public static func parsePercentage(_ phrase: String) -> Int? {
        let clean = phrase.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if clean == "a quarter" || clean == "quarter" { return 25 }
        if clean == "half" || clean == "a half" { return 50 }
        if clean == "three quarters" { return 75 }

        var target = clean
        if target.hasSuffix("%") { target = String(target.dropLast()).trimmingCharacters(in: .whitespaces) }
        if target.hasSuffix("percent") { target = String(target.dropLast(7)).trimmingCharacters(in: .whitespaces) }

        return parseInteger(target)
    }

    /// Parses spoken time phrases like "seven fifteen", "7:15", "seven thirty", "half past seven", "quarter to eight".
    public static func parseSpokenTime(_ phrase: String) -> (hour: Int, minute: Int)? {
        let clean = phrase.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Check HH:MM
        if clean.contains(":") {
            let parts = clean.split(separator: ":").map(String.init)
            if parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) {
                return (h, m)
            }
        }

        // Check "half past X"
        if clean.hasPrefix("half past ") {
            let rest = String(clean.dropFirst(10))
            if let h = parseInteger(rest) { return (h, 30) }
        }

        // Check "quarter past X"
        if clean.hasPrefix("quarter past ") || clean.hasPrefix("a quarter past ") {
            let rest = clean.replacingOccurrences(of: "a quarter past ", with: "").replacingOccurrences(of: "quarter past ", with: "")
            if let h = parseInteger(rest) { return (h, 15) }
        }

        // Check "quarter to X"
        if clean.hasPrefix("quarter to ") || clean.hasPrefix("a quarter to ") {
            let rest = clean.replacingOccurrences(of: "a quarter to ", with: "").replacingOccurrences(of: "quarter to ", with: "")
            if let h = parseInteger(rest) {
                let hour = (h == 1) ? 12 : h - 1
                return (hour, 45)
            }
        }

        let words = clean.split(separator: " ").map(String.init)
        if words.count == 1 {
            let single = words[0]
            if (single.count == 3 || single.count == 4), let num = Int(single), num >= 100 {
                let hour = num / 100
                let minute = num % 100
                if hour >= 0 && hour <= 24 && minute >= 0 && minute < 60 {
                    return (hour, minute)
                }
            }
            if let h = parseInteger(words[0]) {
                return (h, 0)
            }
        } else if words.count == 2 {
            if let h = parseInteger(words[0]), let m = parseInteger(words[1]) {
                return (h, m)
            }
        } else if words.count == 3 {
            // e.g. "seven twenty five"
            if let h = parseInteger(words[0]), let m = parseInteger("\(words[1]) \(words[2])") {
                return (h, m)
            }
        }

        return nil
    }
}
