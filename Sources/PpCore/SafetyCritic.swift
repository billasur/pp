import Foundation

/// Safety gate that vets candidate desktop actions and plan steps before execution.
///
/// Gating is a *veto*, never a vote. Anything that sends data outward, destroys data,
/// spends money, or changes system state always requires explicit confirmation, no
/// matter how confident the decision model is. Confidence only ever adds caution; it
/// can never remove a gate.
public enum SafetyCritic {
    public enum RiskCategory: String, CaseIterable, Sendable {
        case destructive
        case outwardTransmission
        case financialTransaction
        case systemControl
        case promptInjection
    }

    public enum SafetyVerdict: Equatable, Sendable {
        case safe
        case requiresConfirmation(category: RiskCategory, reason: String)
        case vetoed(reason: String)

        public var isBlocked: Bool {
            switch self {
            case .safe: return false
            case .requiresConfirmation, .vetoed: return true
            }
        }

        public var category: RiskCategory? {
            if case .requiresConfirmation(let category, _) = self { return category }
            return nil
        }
    }

    /// A rule either matches an unambiguous verb anywhere, or a phrase that supplies
    /// the context an ambiguous word needs. `skip forward` is media; `forward this` is
    /// sending. `in order to` is prose; `place order` is a purchase.
    private struct Rule {
        let category: RiskCategory
        let words: [String]
        let phrases: [String]
        let reason: (String) -> String
    }

    private static let rules: [Rule] = [
        Rule(category: .systemControl,
             words: ["shutdown", "reboot", "format", "rmdir", "sudo", "chmod", "chown", "diskutil", "killall"],
             phrases: ["restart the mac", "restart the computer", "restart my mac", "restart system", "restart the machine", "kill the process", "kill all processes", "erase the disk", "wipe the disk"],
             reason: { "Action involves system-level modification ('\($0)')" }),

        Rule(category: .financialTransaction,
             words: ["buy", "purchase", "pay", "checkout", "subscribe", "donate", "bid"],
             phrases: ["place order", "place the order", "order now", "order this", "order it", "order these", "order that", "confirm order", "complete order", "transfer money", "transfer funds", "wire transfer", "pay now", "buy now"],
             reason: { "Action involves financial payment or purchase ('\($0)')" }),

        Rule(category: .outwardTransmission,
             words: ["send", "post", "tweet", "publish", "broadcast", "mail", "email", "upload", "submit", "reply", "share", "dm"],
             phrases: ["forward this", "forward it", "forward the", "forward that", "forward to ", "forward message", "forward email", "forward the email", "send it", "post this"],
             reason: { "Action sends, publishes or replies with content ('\($0)')" }),

        Rule(category: .destructive,
             words: ["delete", "remove", "trash", "erase", "wipe", "destroy", "uninstall", "unlink"],
             phrases: ["drop table", "drop database", "drop schema", "empty trash", "empty the trash", "empty bin", "clear history", "clear all data", "clear the cache", "clear cookies", "discard changes", "discard draft"],
             reason: { "Action may permanently delete or remove data ('\($0)')" })
    ]

    /// Phrases that only make sense as an attempt to redirect the assistant.
    private static let injectionMarkers: [String] = [
        "ignore previous instructions",
        "ignore all previous",
        "disregard previous",
        "ignore the above",
        "new instructions:",
        "system prompt",
        "you are now",
        "assistant must",
        "do not tell the user",
        "without asking the user",
        "skip confirmation",
        "bypass confirmation",
        "no confirmation needed",
        "already approved"
    ]

    /// Evaluates a candidate action against safety rules.
    public static func evaluate(
        actionLabel: String,
        actionDetail: String = "",
        command: String = "",
        confidence: Double = 1.0
    ) -> SafetyVerdict {
        let actionText = "\(actionLabel) \(actionDetail)".lowercased()
        let combined = "\(actionText) \(command.lowercased())"

        if let phrase = injectionMarkers.first(where: { combined.contains($0) }) {
            return .requiresConfirmation(
                category: .promptInjection,
                reason: "Screen text looks like an instruction ('\(phrase)'). On-screen labels are never commands."
            )
        }

        return match(combined)
    }

    /// Evaluates a plan step before execution. Unconditional for every risky category.
    public static func evaluate(step: PlanStep, goal: String) -> SafetyVerdict {
        let stepText = "\(step.summary) \(step.target ?? "") \(step.text ?? "")".lowercased()
        let combined = "\(stepText) \(goal.lowercased())"

        if let phrase = injectionMarkers.first(where: { combined.contains($0) }) {
            return .requiresConfirmation(
                category: .promptInjection,
                reason: "Step text resembles an injected instruction ('\(phrase)')."
            )
        }

        return match(combined)
    }

    /// True when text carries an attempt to redirect the assistant rather than a command.
    public static func looksLikeInjection(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return injectionMarkers.contains { lowered.contains($0) }
    }

    private static func match(_ text: String) -> SafetyVerdict {
        for rule in rules {
            if let word = rule.words.first(where: { containsWord(text, word: $0) }) {
                return .requiresConfirmation(category: rule.category, reason: rule.reason(word))
            }
            if let phrase = rule.phrases.first(where: { text.contains($0) }) {
                return .requiresConfirmation(category: rule.category, reason: rule.reason(phrase))
            }
        }
        return .safe
    }

    private static func containsWord(_ text: String, word: String) -> Bool {
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: word))\\b"
        return (try? NSRegularExpression(pattern: pattern).firstMatch(in: text, range: NSRange(text.startIndex..., in: text))) != nil
    }
}
