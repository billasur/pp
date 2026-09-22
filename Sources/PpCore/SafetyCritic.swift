import Foundation

/// Safety gate that vets candidate desktop actions and plan steps to prevent unintended destructive or outward-facing operations.
public enum SafetyCritic {
    public enum RiskCategory: String, CaseIterable, Sendable {
        case destructive
        case outwardTransmission
        case financialTransaction
        case systemControl
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
    }

    private static let destructiveKeywords: Set<String> = [
        "delete", "remove", "trash", "empty", "discard", "clear",
        "erase", "wipe", "destroy", "drop", "uninstall"
    ]

    private static let outwardKeywords: Set<String> = [
        "send", "post", "tweet", "publish", "broadcast", "mail",
        "email", "share", "upload", "submit"
    ]

    private static let financialKeywords: Set<String> = [
        "buy", "purchase", "pay", "checkout", "order", "transfer",
        "wire", "subscribe"
    ]

    private static let systemKeywords: Set<String> = [
        "format", "shutdown", "reboot", "restart", "kill", "rmdir"
    ]

    /// Evaluates a candidate action against safety rules.
    public static func evaluate(
        actionLabel: String,
        actionDetail: String = "",
        command: String = "",
        confidence: Double = 1.0
    ) -> SafetyVerdict {
        let combined = "\(actionLabel) \(actionDetail) \(command)".lowercased()

        // 1. Critical system destruction - always requires confirmation or veto
        for word in systemKeywords {
            if containsWord(combined, word: word) {
                return .requiresConfirmation(
                    category: .systemControl,
                    reason: "Action involves system-level modification ('\(word)')"
                )
            }
        }

        // 2. Financial transactions - always requires confirmation
        for word in financialKeywords {
            if containsWord(combined, word: word) {
                return .requiresConfirmation(
                    category: .financialTransaction,
                    reason: "Action involves financial payment or purchase ('\(word)')"
                )
            }
        }

        // 3. Outward communication - requires confirmation unless confidence is very high
        for word in outwardKeywords {
            if containsWord(combined, word: word) {
                if confidence < 0.90 {
                    return .requiresConfirmation(
                        category: .outwardTransmission,
                        reason: "Action sends or publishes content externally ('\(word)')"
                    )
                }
            }
        }

        // 4. Destructive data loss - requires confirmation if confidence < 0.85
        for word in destructiveKeywords {
            if containsWord(combined, word: word) {
                if confidence < 0.85 {
                    return .requiresConfirmation(
                        category: .destructive,
                        reason: "Action may permanently delete or remove data ('\(word)')"
                    )
                }
            }
        }

        return .safe
    }

    /// Evaluates a plan step before execution.
    public static func evaluate(step: PlanStep, goal: String) -> SafetyVerdict {
        let text = "\(step.summary) \(step.target ?? "") \(step.text ?? "") \(goal)".lowercased()

        for word in financialKeywords {
            if containsWord(text, word: word) {
                return .requiresConfirmation(category: .financialTransaction, reason: "Plan step executes a financial transaction ('\(word)')")
            }
        }

        for word in systemKeywords {
            if containsWord(text, word: word) {
                return .requiresConfirmation(category: .systemControl, reason: "Plan step executes a system operation ('\(word)')")
            }
        }

        for word in outwardKeywords {
            if containsWord(text, word: word) {
                return .requiresConfirmation(category: .outwardTransmission, reason: "Plan step sends or publishes data ('\(word)')")
            }
        }

        for word in destructiveKeywords {
            if containsWord(text, word: word) {
                return .requiresConfirmation(category: .destructive, reason: "Plan step deletes or removes items ('\(word)')")
            }
        }

        return .safe
    }

    private static func containsWord(_ text: String, word: String) -> Bool {
        // Use word boundary matching
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: word))\\b"
        return (try? NSRegularExpression(pattern: pattern).firstMatch(in: text, range: NSRange(text.startIndex..., in: text))) != nil
    }
}
