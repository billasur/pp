import Foundation

/// One element read from the accessibility tree, reduced to what ranking needs.
public struct UICandidate: Equatable, Sendable {
    public enum Role: String, Sendable, CaseIterable {
        case button, link, textField, menuItem, tab, checkbox, radioButton, slider
        case popUpButton, listItem, staticText, other

        /// How likely this role is to be the thing a spoken command means.
        public var affinity: Double {
            switch self {
            case .button: return 1.0
            case .link, .textField: return 0.95
            case .menuItem: return 0.9
            case .tab, .checkbox, .radioButton, .popUpButton: return 0.85
            case .listItem: return 0.7
            case .slider: return 0.5
            case .staticText, .other: return 0.2
            }
        }
    }

    public let id: String
    public let label: String
    public let detail: String
    public let role: Role
    public let depth: Int
    public let lastSeenAt: Date?

    public init(id: String, label: String, detail: String, role: Role = .other, depth: Int = 0, lastSeenAt: Date? = nil) {
        self.id = id; self.label = label; self.detail = detail
        self.role = role; self.depth = depth; self.lastSeenAt = lastSeenAt
    }

    public var isNamed: Bool { !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// Deterministic filter-and-rank in front of the decision model.
///
/// This is not an optimisation, it is correctness: the head block shrinks each option
/// to `max(4, (192-16)/n)` tokens, so at 20 options every label is down to 8 tokens.
/// Ranking the right thing into the top 16 is what keeps target selection readable.
public enum Shortlister {
    /// The practical ceiling: above this, option text is too short to distinguish.
    public static let defaultLimit = 16

    public struct Options: Sendable {
        public var limit: Int
        /// Extra weight for labels the user has used successfully before.
        public var priorBoost: [String: Double]
        public var now: Date

        public init(limit: Int = Shortlister.defaultLimit, priorBoost: [String: Double] = [:], now: Date = Date()) {
            self.limit = limit; self.priorBoost = priorBoost; self.now = now
        }
    }

    public static func tokenize(_ text: String) -> Set<String> {
        Set(text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 2 })
    }

    /// Ranks candidates for a command. Pure: same inputs, same order, always.
    public static func rank(
        _ candidates: [UICandidate],
        command: String,
        options: Options = Options()
    ) -> [Candidate] {
        let goalTokens = tokenize(command)
        let scored = candidates
            .filter { $0.isNamed }
            .map { candidate -> (UICandidate, Double) in
                var score = candidate.role.affinity
                let labelTokens = tokenize(candidate.label)
                let detailTokens = tokenize(candidate.detail)

                // Direct mention in the command is the strongest signal.
                let labelOverlap = Double(labelTokens.intersection(goalTokens).count)
                let detailOverlap = Double(detailTokens.intersection(goalTokens).count)
                score += labelOverlap * 3.0
                score += detailOverlap * 0.5

                // A label fully contained in the command ("Send" in "send this to Diya").
                if !labelTokens.isEmpty, labelTokens.isSubset(of: goalTokens) { score += 2.0 }

                // Shallower elements are usually the actionable ones.
                score -= Double(min(candidate.depth, 6)) * 0.05

                if let seen = candidate.lastSeenAt, options.now.timeIntervalSince(seen) < 30 { score += 0.3 }

                let key = candidate.label.lowercased()
                if let boost = options.priorBoost[key] { score += boost }

                return (candidate, score)
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.id < rhs.0.id  // stable, so the same screen ranks the same way
            }

        return scored.prefix(options.limit).map { Candidate(id: $0.0.id, label: $0.0.label, detail: $0.0.detail) }
    }

    /// Whether the ranked list had to drop anything, which tells the caller the
    /// decision was made from a shortlist rather than the whole screen.
    public static func didTruncate(_ candidates: [UICandidate], limit: Int = Shortlister.defaultLimit) -> Bool {
        candidates.filter { $0.isNamed }.count > limit
    }
}
