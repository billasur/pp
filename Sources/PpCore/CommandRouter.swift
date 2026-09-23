import Foundation

public enum CommandLane: String, Sendable, Equatable, Codable {
    case dismissal
    case session
    case time
    case web
    case message
    case note
    case system
    case direct
    case grammar
    case model
}

public struct CommandRoute: Equatable, Sendable {
    public let lane: CommandLane
    public let text: String
    public let summary: String

    public init(lane: CommandLane, text: String, summary: String = "") {
        self.lane = lane
        self.text = text
        self.summary = summary
    }
}

/// Pure deterministic router directing user speech to the correct execution lane.
///
/// Precedence:
/// dismissal → session/wake → TimeIntent → WebIntent → MessageIntent →
/// SystemIntent → DirectIntent (app/quit) → GrammarPlanner → model
public enum CommandRouter {
    public static func route(text: String, frontApp: String = "Finder") -> CommandRoute {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:\"'"))
        guard !trimmed.isEmpty else {
            return CommandRoute(lane: .model, text: text, summary: "Empty")
        }

        // 1. Dismissal
        if let dismissal = DismissalPhrase.match(trimmed) {
            return CommandRoute(lane: .dismissal, text: trimmed, summary: dismissal == .cancel ? "Cancel" : "Dismiss")
        }

        // 2. Session / Bare Wake
        if let match = WakeMatcher.match(in: trimmed) {
            if match.command.isEmpty {
                return CommandRoute(lane: .session, text: trimmed, summary: "Wake / Session")
            }
        }

        // 3. TimeIntent (Alarms / Timers)
        let timeIntent = TimeIntentParser.parse(trimmed)
        if timeIntent.isActionable {
            return CommandRoute(lane: .time, text: trimmed, summary: "Time")
        }

        // 4. WebIntent (Web Navigation / Search / Play)
        let webIntent = WebIntentParser.parse(trimmed)
        if webIntent != .none {
            return CommandRoute(lane: .web, text: trimmed, summary: "Web")
        }

        // 5. MessageIntent (WhatsApp / Messages)
        let messageIntent = MessageIntentParser.parse(trimmed)
        if messageIntent.isActionable {
            return CommandRoute(lane: .message, text: trimmed, summary: "Message")
        }

        // 6. NoteIntent (Notes / Tasks)
        let noteIntent = NoteIntentParser.parse(trimmed, frontApp: frontApp)
        if noteIntent.isActionable {
            return CommandRoute(lane: .note, text: trimmed, summary: "Note")
        }

        // 7. SystemIntent (Volume / Brightness / DND / Sleep / Lock / Settings)
        let systemIntent = SystemIntentParser.parse(trimmed)
        if systemIntent.isActionable {
            return CommandRoute(lane: .system, text: trimmed, summary: "System")
        }

        // 7. DirectIntent (Deterministic App Launch / Quit)
        let directIntent = DirectIntentParser.parse(trimmed)
        if directIntent != .none {
            return CommandRoute(lane: .direct, text: trimmed, summary: "Direct")
        }

        // 8. GrammarPlanner
        if GrammarPlanner.isGrammarCommand(trimmed) {
            let grammarSteps = GrammarPlanner.parseClause(trimmed, frontApp: frontApp)
            if !grammarSteps.isEmpty {
                return CommandRoute(lane: .grammar, text: trimmed, summary: "Grammar")
            }
        }

        // 9. Model fallback
        return CommandRoute(lane: .model, text: trimmed, summary: "Model")
    }
}
