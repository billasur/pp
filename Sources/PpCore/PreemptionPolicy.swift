import Foundation

public struct PartialObservation: Equatable, Sendable {
    public let clause: String
    public let isFinal: Bool
    public let monotonicTime: TimeInterval

    public init(clause: String, isFinal: Bool, monotonicTime: TimeInterval) {
        self.clause = clause
        self.isFinal = isFinal
        self.monotonicTime = monotonicTime
    }
}

public enum PreemptionDecision: Equatable, Sendable {
    case wait
    case preempt(step: PlanStep, clause: String)
    case supersede(step: PlanStep, clause: String)
}

public struct PreemptionPolicy: Sendable {
    public let minimumStableObservations: Int
    public let minimumCharacters: Int
    public let allowed: Set<PlanStep.Kind>
    public let cooldown: TimeInterval

    private var observationCounts: [String: Int] = [:]
    private var lastPreemptedTime: TimeInterval?
    private var lastPreemptedStep: PlanStep?
    private var lastPreemptedClause: String?
    private var superseded: Bool = false

    public init(
        minimumStableObservations: Int = 2,
        minimumCharacters: Int = 8,
        allowed: Set<PlanStep.Kind> = [.openApp, .quitApp, .openURL],
        cooldown: TimeInterval = 1.5
    ) {
        self.minimumStableObservations = minimumStableObservations
        self.minimumCharacters = minimumCharacters
        self.allowed = allowed
        self.cooldown = cooldown
    }

    /// Observes a streaming speech partial and determines if an allowlisted action should be preemptively taken.
    ///
    /// Rules in order:
    /// 1. If `isFinal` is true, return `.wait`; the final path owns final execution and must not double-run.
    /// 2. Parse the clause through `DirectIntentParser`; if it does not map to a kind in `allowed`, return `.wait`.
    /// 3. Require stability: the clause must be byte-identical across at least `minimumStableObservations` observations.
    /// 4. Require at least `minimumCharacters` characters.
    /// 5. Require at least `cooldown` seconds since the previous preempt, preventing repeated launches from a stuttering recognizer.
    /// 6. If an earlier preempt occurred and a newly stable clause names a different target, return `.supersede` once.
    ///    Note: The first app may already be open; both effects are visible and non-destructive, and silently keeping the old target is worse.
    public mutating func observe(_ observation: PartialObservation) -> PreemptionDecision {
        // Rule 1: Final path owns final execution
        guard !observation.isFinal else { return .wait }

        // Rule 4: Minimum characters check on raw clause
        let rawClause = observation.clause
        guard rawClause.count >= minimumCharacters else { return .wait }

        // Rule 2: Parse through DirectIntentParser and check allowed kind and safety
        let intent = DirectIntentParser.parse(rawClause)
        guard intent != .none, let step = makeStep(from: intent), allowed.contains(step.kind) else {
            return .wait
        }
        guard SafetyCritic.evaluate(step: step, goal: rawClause) == .safe else {
            return .wait
        }

        // Rule 3: Require stability (byte-identical across minimumStableObservations)
        let count = (observationCounts[rawClause] ?? 0) + 1
        observationCounts[rawClause] = count
        guard count >= minimumStableObservations else {
            return .wait
        }

        // Rule 6: Check for mid-sentence correction (.supersede)
        if let lastStep = lastPreemptedStep {
            if lastStep != step {
                if !superseded {
                    superseded = true
                    lastPreemptedStep = step
                    lastPreemptedClause = rawClause
                    lastPreemptedTime = observation.monotonicTime
                    return .supersede(step: step, clause: rawClause)
                }
                return .wait
            } else {
                // Same target already preempted
                return .wait
            }
        }

        // Rule 5: Cooldown since previous preempt
        if let lastTime = lastPreemptedTime, observation.monotonicTime - lastTime < cooldown {
            return .wait
        }

        // First preempt trigger
        lastPreemptedTime = observation.monotonicTime
        lastPreemptedStep = step
        lastPreemptedClause = rawClause
        return .preempt(step: step, clause: rawClause)
    }

    private func makeStep(from intent: DirectIntent) -> PlanStep? {
        switch intent {
        case .openApp(let name):
            return PlanStep(kind: .openApp, target: name)
        case .quitApp(let name):
            return PlanStep(kind: .quitApp, target: name)
        case .openSite(let host):
            return PlanStep(kind: .openURL, target: host)
        case .none:
            return nil
        }
    }

    /// Computes the remainder of an utterance after removing the consumed preempted clause.
    ///
    /// Rules:
    /// - Computes against normalized strings.
    /// - Strips trailing connector words such as "and" and "then".
    /// - Returns an empty remainder (`""`) when nothing remains.
    /// - If removing `consumed` would begin the remainder in the middle of a word, returns `nil` (never a mangled string).
    public static func takeRemainder(full: String, consumed: String) -> String? {
        let normFull = DirectIntentParser.normalize(full)
        let normConsumed = DirectIntentParser.normalize(consumed)

        guard !normConsumed.isEmpty else { return normFull }
        guard normFull != normConsumed else { return "" }

        guard normFull.hasPrefix(normConsumed) else {
            return nil
        }

        // Check if removal lands on a word boundary
        let dropIndex = normFull.index(normFull.startIndex, offsetBy: normConsumed.count)
        if dropIndex < normFull.endIndex {
            let nextChar = normFull[dropIndex]
            guard nextChar.isWhitespace || nextChar.isPunctuation else {
                // Starts mid-word!
                return nil
            }
        }

        var remainder = String(normFull[dropIndex...]).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: " .,!?;:")))

        // Strip connector words at the beginning of the remainder
        let connectors = ["and", "then", "also", "and then"]
        var stripped = true
        while stripped {
            stripped = false
            for connector in connectors {
                if remainder == connector {
                    remainder = ""
                    stripped = true
                    break
                }
                if remainder.hasPrefix(connector + " ") {
                    remainder = String(remainder.dropFirst(connector.count + 1)).trimmingCharacters(in: .whitespaces)
                    stripped = true
                    break
                }
            }
        }

        return remainder
    }
}
