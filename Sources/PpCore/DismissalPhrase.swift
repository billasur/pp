import Foundation

/// Analyzes spoken phrases to determine if the user intends to dismiss or cancel the assistant.
///
/// Negatives are essential:
/// - "stop the music" -> NOT a dismissal (it's a command)
/// - "cancel my subscription" -> NOT a dismissal (it's a command)
/// - "thank you for the notes" -> NOT a dismissal (it's gratitude with follow-up / command context)
/// Pure dismissals:
/// - "thank you", "thanks", "that's all", "dismiss", "nevermind", "go away"
/// Hard cancels (equal to pressing Escape):
/// - "stop", "cancel"
public enum DismissalKind: Equatable, Sendable {
    case dismiss
    case cancel
}

public enum DismissalPhrase {
    public static func match(_ utterance: String) -> DismissalKind? {
        let trimmed = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:-—\"'"))

        // Exact cancellations (Escape equivalent)
        if trimmed == "stop" || trimmed == "cancel" {
            return .cancel
        }

        // Polite / conversational dismissals
        let politeExact: Set<String> = [
            "thank you",
            "thanks",
            "thanks pp",
            "thank you pp",
            "that's all",
            "thats all",
            "that's all thanks",
            "thats all thanks",
            "dismiss",
            "never mind",
            "nevermind",
            "go away",
            "bye",
            "goodbye"
        ]

        if politeExact.contains(trimmed) {
            return .dismiss
        }

        return nil
    }
}
