import Foundation

/// What pp remembers between the clauses of one spoken command.
///
/// Chained commands are pronouns and ellipsis: "open Zen, find the launch notes, send
/// **the link** to **Diya**". Remembering the noun each later clause refers to is the
/// difference between a chain working and three unrelated commands.
public struct SessionFacts: Equatable, Sendable {
    public var lastApp: String?
    public var lastURL: String?
    public var lastTarget: String?
    public var lastAction: String?
    public var lastPerson: String?
    public var clauses: [String] = []

    public init() {}
}

/// Session memory across the clauses of a command. Thread-safe; scoped to one command
/// and cleared when it finishes.
public final class SessionStore: @unchecked Sendable {
    private let lock = NSLock()
    private var facts = SessionFacts()

    public init() {}

    public func snapshot() -> SessionFacts {
        lock.lock(); defer { lock.unlock() }
        return facts
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        facts = SessionFacts()
    }

    /// Records what just happened, then returns the facts for building the next clause.
    @discardableResult
    public func record(
        clause: String,
        action: String? = nil,
        app: String? = nil,
        url: String? = nil,
        target: String? = nil
    ) -> SessionFacts {
        lock.lock(); defer { lock.unlock() }
        facts.clauses.append(clause)
        if let action { facts.lastAction = action }
        if let app { facts.lastApp = app }
        if let url { facts.lastURL = url }
        if let target { facts.lastTarget = target }
        if let person = SessionStore.person(in: clause) { facts.lastPerson = person }
        return facts
    }

    /// A short note appended to the decision state so a pronoun has a referent.
    ///
    /// Also remembers anyone named explicitly in this clause, so the *next* clause can
    /// say "them" and mean them.
    public func contextNote(for clause: String) -> String? {
        let named = SessionStore.person(in: clause)
        let lowered = clause.lowercased()
        let mentionedPerson = named

        lock.lock()
        if let named { facts.lastPerson = named }
        let current = facts
        lock.unlock()

        var parts: [String] = []
        if SessionStore.refersToIt(lowered) {
            if let app = current.lastApp { parts.append("'it' refers to \(app)") }
            if let target = current.lastTarget { parts.append("'that' refers to \(target)") }
        }
        if SessionStore.refersToLink(lowered), let url = current.lastURL {
            parts.append("'the link' refers to \(url)")
        }
        // Only annotate a person pronoun when the clause did not name the person itself.
        if mentionedPerson == nil, SessionStore.refersToPerson(lowered), let person = current.lastPerson {
            parts.append("'\(SessionStore.personPronoun(in: lowered) ?? "they")' refers to \(person)")
        }
        if SessionStore.refersToThere(lowered), let app = current.lastApp {
            parts.append("'there' refers to \(app)")
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: ", ")
    }

    /// Resolves a whole clause's referent, or nil when the clause stands alone.
    public func resolve(reference: String) -> String? {
        let facts = snapshot()
        if let person = SessionStore.person(in: reference) { return person }
        let lowered = reference.lowercased()
        if SessionStore.refersToLink(lowered) { return facts.lastURL }
        if SessionStore.refersToPerson(lowered) { return facts.lastPerson }
        if SessionStore.refersToIt(lowered) { return facts.lastTarget ?? facts.lastApp }
        if SessionStore.refersToThere(lowered) { return facts.lastApp }
        return nil
    }

    // MARK: Rule helpers

    static func refersToIt(_ text: String) -> Bool {
        containsWord(text, "it") || containsWord(text, "that") || containsWord(text, "this")
    }

    static func refersToLink(_ text: String) -> Bool {
        text.contains("the link") || text.contains("that link") || text.contains("them the link")
    }

    static func refersToPerson(_ text: String) -> Bool {
        ["him", "her", "them", "to her", "to him"].contains { containsWord(text, $0) }
    }

    static func refersToThere(_ text: String) -> Bool { containsWord(text, "there") }

    static func personPronoun(in text: String) -> String? {
        ["him", "her", "them"].first { containsWord(text, $0) }
    }

    /// "send the link to Diya" -> "Diya". Only a capitalised word after "to", which is
    /// a rule, not a name database.
    public static func person(in clause: String) -> String? {
        let pattern = "\\b(?:to|for)\\s+([A-Z][A-Za-z'\\-]{1,30})"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: clause, range: NSRange(clause.startIndex..., in: clause)),
              let range = Range(match.range(at: 1), in: clause) else { return nil }
        let name = String(clause[range])
        // Sentence-initial words are not names ("Then open Finder").
        let stopWords: Set<String> = ["The", "Then", "And", "Also", "Please", "Open", "Then,", "Next"]
        return stopWords.contains(name) ? nil : name
    }

    private static func containsWord(_ text: String, _ word: String) -> Bool {
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: word))\\b"
        return (try? NSRegularExpression(pattern: pattern).firstMatch(in: text, range: NSRange(text.startIndex..., in: text))) != nil
    }
}
