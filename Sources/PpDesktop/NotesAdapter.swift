import Foundation
import AppKit

public enum NotesAdapter {
    /// Creates a new task/note in Notes.app.
    public static func create(text: String = "", isTask: Bool = true) async throws -> Bool {
        let escapedText = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let script: String
        if isTask {
            let taskTitle = escapedText.isEmpty ? "Tasks" : escapedText
            let bodyHTML = "<div><h1>\(taskTitle)</h1></div><div><input type=\\\"checkbox\\\"> \(escapedText.isEmpty ? "" : escapedText)</div>"
            script = """
            tell application "Notes"
                activate
                set newNote to make new note with properties {name:"\(taskTitle)", body:"\(bodyHTML)"}
                show newNote
            end tell
            return "true"
            """
        } else {
            let noteTitle = escapedText.isEmpty ? "New Note" : escapedText
            let bodyHTML = "<div><h1>\(noteTitle)</h1></div><div>\(escapedText)</div>"
            script = """
            tell application "Notes"
                activate
                set newNote to make new note with properties {name:"\(noteTitle)", body:"\(bodyHTML)"}
                show newNote
            end tell
            return "true"
            """
        }

        do {
            let res = try await ScriptRunner.run(source: script, timeout: 5.0)
            return res != nil
        } catch {
            return false
        }
    }

    /// Changes the heading / title of the currently selected note in Notes.app.
    public static func changeHeading(to newHeading: String) async throws -> Bool {
        let escaped = newHeading
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
        tell application "Notes"
            activate
            set sel to selection
            if sel is not {} then
                set aNote to item 1 of sel
                set oldBody to body of aNote
                set name of aNote to "\(escaped)"
                return "true"
            else
                -- Try first note if none selected
                set allNotes to notes
                if allNotes is not {} then
                    set aNote to item 1 of allNotes
                    set name of aNote to "\(escaped)"
                    return "true"
                end if
            end if
        end tell
        return "false"
        """

        do {
            let res = try await ScriptRunner.run(source: script, timeout: 5.0)
            return res?.contains("true") == true
        } catch {
            return false
        }
    }

    /// Replaces the current line where the cursor is in Notes.app with new text.
    public static func changeCurrentLine(to newText: String) async throws -> Bool {
        let escaped = newText
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
        tell application "Notes" to activate
        delay 0.1
        tell application "System Events"
            tell process "Notes"
                -- Cmd + Left (jump to line start)
                key code 123 using command down
                delay 0.05
                -- Shift + Cmd + Right (select to line end)
                key code 124 using {command down, shift down}
                delay 0.05
                keystroke "\(escaped)"
            end tell
        end tell
        return "true"
        """

        do {
            let res = try await ScriptRunner.run(source: script, timeout: 5.0)
            return res != nil
        } catch {
            return false
        }
    }

    /// Replaces target text with replacement text in the active note's body.
    public static func replaceText(target: String, replacement: String) async throws -> Bool {
        let escapedTarget = target
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let escapedReplacement = replacement
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
        tell application "Notes"
            set sel to selection
            if sel is not {} then
                set aNote to item 1 of sel
                set currentBody to body of aNote
                set AppleScript's text item delimiters to "\(escapedTarget)"
                set textItems to every text item of currentBody
                set AppleScript's text item delimiters to "\(escapedReplacement)"
                set newBody to textItems as string
                set body of aNote to newBody
                return "true"
            end if
        end tell
        return "false"
        """

        do {
            let res = try await ScriptRunner.run(source: script, timeout: 5.0)
            return res?.contains("true") == true
        } catch {
            return false
        }
    }
}
