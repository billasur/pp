import Foundation

public enum NoteIntent: Equatable, Sendable {
    case create(text: String, isTask: Bool)
    case changeHeading(to: String)
    case changeCurrentLine(to: String)
    case replaceText(target: String, replacement: String)
    case append(text: String)
    case none

    public var isActionable: Bool {
        self != .none
    }
}

public enum NoteIntentParser {
    public static func parse(_ utterance: String, frontApp: String = "") -> NoteIntent {
        let trimmed = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:\"'"))
        guard !trimmed.isEmpty else { return .none }
        let lower = trimmed.lowercased()

        // 1. Heading change:
        // "change the heading to X", "change heading to X", "change title to X", "change the title to X", "set heading to X"
        let headingPrefixes = [
            "change the heading to ",
            "change heading to ",
            "change the title to ",
            "change title to ",
            "set heading to ",
            "set title to ",
            "rename note to ",
            "rename this note to "
        ]
        for p in headingPrefixes {
            if lower.hasPrefix(p) {
                let rest = String(trimmed.dropFirst(p.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !rest.isEmpty {
                    return .changeHeading(to: rest)
                }
            }
        }

        // 2. Change current line:
        // "change this line to X", "replace this line with X", "change current line to X", "update this line to X"
        let linePrefixes = [
            "change this line to ",
            "replace this line with ",
            "change current line to ",
            "replace current line with ",
            "update this line to ",
            "set this line to "
        ]
        for p in linePrefixes {
            if lower.hasPrefix(p) {
                let rest = String(trimmed.dropFirst(p.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !rest.isEmpty {
                    return .changeCurrentLine(to: rest)
                }
            }
        }

        // 3. Text replacement:
        // "replace X with Y" (if in Notes or utterance mentions note)
        if lower.hasPrefix("replace ") {
            let rest = String(trimmed.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines)
            let lowerRest = rest.lowercased()
            if let withRange = lowerRest.range(of: " with ") {
                let target = String(rest[..<withRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let replacement = String(rest[withRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !target.isEmpty && !replacement.isEmpty {
                    return .replaceText(target: target, replacement: replacement)
                }
            }
        }

        // 4. Note creation / Task creation:
        // "create new task in the notes app", "create a task in notes", "create task in notes", "new task in notes"
        let taskPrefixes = [
            "create new task in the notes app",
            "create a new task in the notes app",
            "create new task in notes app",
            "create a new task in notes app",
            "create new task in notes",
            "create a new task in notes",
            "create task in the notes app",
            "create a task in the notes app",
            "create task in notes app",
            "create a task in notes app",
            "create task in notes",
            "create a task in notes",
            "new task in the notes app",
            "new task in notes app",
            "new task in notes",
            "add task in the notes app",
            "add task in notes app",
            "add task in notes",
            "add a task in the notes app",
            "add a task in notes app",
            "add a task in notes"
        ]
        for p in taskPrefixes {
            if lower == p {
                return .create(text: "", isTask: true)
            }
            if lower.hasPrefix(p + " ") {
                let rest = String(trimmed.dropFirst(p.count + 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                let cleanRest = rest.hasPrefix("to ") ? String(rest.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines) : rest
                return .create(text: cleanRest, isTask: true)
            }
        }

        // 5. Generic note creation:
        // "create new note in the notes app", "create a note in notes", "new note in notes"
        let notePrefixes = [
            "create new note in the notes app",
            "create a new note in the notes app",
            "create new note in notes app",
            "create a new note in notes app",
            "create new note in notes",
            "create a new note in notes",
            "create note in the notes app",
            "create a note in the notes app",
            "create note in notes app",
            "create a note in notes app",
            "create note in notes",
            "create a note in notes",
            "new note in the notes app",
            "new note in notes app",
            "new note in notes",
            "take a note in the notes app",
            "take a note in notes app",
            "take a note in notes",
            "take a note",
            "make a note in the notes app",
            "make a note in notes app",
            "make a note in notes"
        ]
        for p in notePrefixes {
            if lower == p {
                return .create(text: "", isTask: false)
            }
            if lower.hasPrefix(p + " ") {
                let rest = String(trimmed.dropFirst(p.count + 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                return .create(text: rest, isTask: false)
            }
        }

        // 6. Appending text to active note:
        // "append X to notes", "add line X to notes", "add to notes X"
        if lower.hasPrefix("append ") && lower.contains("to note") {
            let rest = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
            if let toRange = rest.lowercased().range(of: " to note") {
                let text = String(rest[..<toRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                return .append(text: text)
            }
        }

        return .none
    }
}
