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

    private var observationTimestamps: [(clause: String, time: TimeInterval)] = []
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
    /// 3. Require stability: the clause must be byte-identical across at least `minimumStableObservations` observations within a ~10s window.
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

        // Rule 3: Require stability (byte-identical across minimumStableObservations in a 10s window)
        let now = observation.monotonicTime
        observationTimestamps.append((clause: rawClause, time: now))
        observationTimestamps.removeAll(where: { now - $0.time > 10.0 })

        let count = observationTimestamps.filter({ $0.clause == rawClause }).count
        guard count >= minimumStableObservations else {
            return .wait
        }

        // Rule 5: Cooldown since previous preempt applies to every preempt
        if let lastTime = lastPreemptedTime, observation.monotonicTime - lastTime < cooldown {
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

        // First preempt trigger
        lastPreemptedTime = observation.monotonicTime
        lastPreemptedStep = step
        lastPreemptedClause = rawClause
        superseded = false
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
    /// Guarantees:
    /// - Result is an exact byte-for-byte substring of `full`.
    /// - If consumed is empty, returns full.
    /// - If full matches consumed, returns "".
    /// - If remainder starts mid-word, returns nil.
    /// - Strips leading connector words ("and", "then", "also", "and then").
    public static func takeRemainder(full: String, consumed: String) -> String? {
        let fullSpans = DirectIntentParser.tokenSpans(full)
        let consumedSpans = DirectIntentParser.tokenSpans(consumed)

        guard !consumedSpans.isEmpty else { return full }
        if fullSpans.count == consumedSpans.count && zip(fullSpans, consumedSpans).allSatisfy({ $0.0.token == $0.1.token }) {
            return ""
        }

        guard fullSpans.count >= consumedSpans.count else { return nil }

        // Must match as prefix tokens
        for i in 0..<consumedSpans.count {
            if fullSpans[i].token != consumedSpans[i].token {
                return nil
            }
        }

        // Find the index in `full` right after the consumed tokens
        // The corresponding range in `full` is fullSpans[consumedSpans.count - 1].range
        let fullConsumedEnd = fullSpans[consumedSpans.count - 1].range.upperBound

        // Check mid-word condition: if there is a character immediately following fullConsumedEnd that is alphanumeric / part of word
        if fullConsumedEnd < full.endIndex {
            let nextChar = full[fullConsumedEnd]
            if !nextChar.isWhitespace && !".,!?;:".contains(nextChar) {
                // Sliced mid-word!
                return nil
            }
        }

        var remainingSpans = Array(fullSpans[consumedSpans.count...])
        if remainingSpans.isEmpty {
            return ""
        }

        // Strip connector words from remainingSpans ("and", "then", "also", "and then")
        while !remainingSpans.isEmpty {
            let first = remainingSpans[0].token
            if first == "and" || first == "then" || first == "also" {
                remainingSpans.removeFirst()
                continue
            }
            if remainingSpans.count >= 2 && remainingSpans[0].token == "and" && remainingSpans[1].token == "then" {
                remainingSpans.removeFirst(2)
                continue
            }
            break
        }

        guard let firstValidSpan = remainingSpans.first else {
            return ""
        }

        let remainderSlice = full[firstValidSpan.range.lowerBound...]
        return remainderSlice.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: " .,!?;:")))
    }
}
