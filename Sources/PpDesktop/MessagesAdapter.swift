import Foundation

public enum MessagesAdapter {
    /// Sends a message via Messages.app using AppleScript.
    /// This works with buddy handles (phone numbers, emails) or service chats.
    public static func send(text: String, to recipient: String) async throws -> Bool {
        let escapedText = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let escapedRecipient = recipient
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
        tell application "Messages"
            set targetService to 1st service whose service type = iMessage
            set targetBuddy to buddy "\(escapedRecipient)" of targetService
            send "\(escapedText)" to targetBuddy
        end tell
        """

        do {
            let result = try await ScriptRunner.run(source: script, timeout: 5.0)
            return result != nil
        } catch {
            // Fallback: try default target without explicit service
            let fallbackScript = """
            tell application "Messages"
                send "\(escapedText)" to buddy "\(escapedRecipient)"
            end tell
            """
            do {
                let fbResult = try await ScriptRunner.run(source: fallbackScript, timeout: 5.0)
                return fbResult != nil
            } catch {
                throw error
            }
        }
    }
}
