import Foundation

/// Decides what can be worked out while the user is still speaking.
///
/// The plan's latency trick: the router question and the accessibility read do not need
/// the finished sentence, so they can start on a partial transcript. What must *not*
/// happen early is acting — a partial transcript is not a command until the
/// end-of-utterance signal says the clause is closed.
public struct PartialRouter: Sendable {
    public enum Readiness: Equatable, Sendable {
        /// Too little to work with, or the sentence is mid-clause.
        case wait
        /// Enough to pre-compute a route, but never enough to act.
        case preroute(clause: String)
    }

    /// Words that mean the sentence continues: do not commit on these.
    public static let continuationWords: Set<String> = [
        "and", "then", "also", "or", "plus", "after", "before", "with", "to", "the", "a", "an", "in", "on", "for"
    ]

    public let minimumTokens: Int

    public init(minimumTokens: Int = 3) {
        self.minimumTokens = minimumTokens
    }

    /// What can be done with this partial transcript right now.
    public func consider(partial: String) -> Readiness {
        let tokens = PartialRouter.tokens(partial)
        guard tokens.count >= minimumTokens else { return .wait }
        // A trailing connector means another clause is coming; pre-routing now would
        // be pre-routing the wrong sentence.
        guard let last = tokens.last, !Self.continuationWords.contains(last) else { return .wait }
        return .preroute(clause: partial.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Whether a decision reached from a partial transcript may be executed.
    /// Only a closed clause may be acted on, so this is the one place partial and
    /// final handling meet.
    public func mayAct(partial: String, clauseClosed: Bool) -> Bool {
        clauseClosed && !partial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static func tokens(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}

/// Rolling holder for pre-computed work, keyed so a late correction invalidates it.
public final class PrerouteCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: (clause: String, value: String)?

    public init() {}

    public func store(clause: String, value: String) {
        lock.lock(); defer { lock.unlock() }
        cached = (clause, value)
    }

    /// Returns the cached value only when the final transcript still starts with the
    /// text it was computed from. Otherwise the pre-computation was wasted, which is
    /// the correct outcome and cheaper than acting on a guess.
    public func take(ifMatching finalTranscript: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let cached else { return nil }
        let normalized = finalTranscript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.hasPrefix(cached.clause.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return cached.value
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        cached = nil
    }
}
