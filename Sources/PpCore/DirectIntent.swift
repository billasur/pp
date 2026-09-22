import Foundation

/// A command whose whole meaning is fixed by its words.
///
/// "Open Notes" needs no decision: the target is named, the action is fixed, and nothing
/// on screen can change either. These are the commands that can be finished while the user
/// is still speaking, so they get their own parser — and anything short of certain is
/// `.none`, which sends the command down the ordinary path.
///
/// The parser is deliberately narrow. A wrong guess here would launch something the user
/// did not ask for, so it accepts only a bare verb and a bare name, with nothing between
/// them and nothing after them.
public enum DirectIntent: Equatable, Sendable {
    case openApp(name: String)
    case quitApp(name: String)
    case openSite(host: String)
    case none

    public var target: String? {
        switch self {
        case .openApp(let name), .quitApp(let name): return name
        case .openSite(let host): return host
        case .none: return nil
        }
    }

    /// Whether this is a shape pp is willing to act on without asking the model.
    public var isDeterministic: Bool { self != .none }
}

public enum DirectIntentParser {
    /// Filler at the front that carries no meaning.
    private static let leadIns = ["hey pp", "hey pp,", "pp", "okay", "ok", "please", "can you", "could you",
                                  "would you", "i want to", "i'd like to", "just", "quickly"]
    /// Longest first, so "shut down" is not read as "shut".
    private static let quitVerbs = ["shut down", "quit", "close", "exit", "shut"]
    private static let openVerbs = ["switch to", "go to", "bring up", "show me", "open up", "launch", "open", "start", "show", "switch"]
    private static let siteVerbs = ["go to", "navigate to", "visit", "open up", "open"]

    /// More than this and the "name" is really a sentence.
    private static let maxNameWords = 3
    /// Prepositions mean the words after the verb form a sentence, not a name:
    /// "open the window in Notes" is not an app called "window in notes".
    private static let forbiddenInNames: Set<String> = ["in", "on", "at", "for", "to", "from", "with", "of", "into", "inside"]

    public static func parse(_ clause: String) -> DirectIntent {
        let text = trimLeadIns(normalize(clause))
        guard !text.isEmpty, !containsConjunction(text) else { return .none }
        if let host = siteTarget(in: text) { return .openSite(host: host) }
        if let name = name(in: text, after: quitVerbs) { return .quitApp(name: name) }
        if let name = name(in: text, after: openVerbs) { return .openApp(name: name) }
        return .none
    }

    // MARK: - Pieces

    /// "Open Notes." and "open  NOTes" are the same command.
    static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        let words = lowered.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " .,!?;:"))
    }

    private static func trimLeadIns(_ text: String) -> String {
        var result = text
        var changed = true
        while changed {
            changed = false
            for lead in leadIns where result.hasPrefix(lead + " ") {
                result = String(result.dropFirst(lead.count + 1))
                changed = true
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
    }

    /// A second clause means a chain, and a chain is a plan, not a single launch.
    private static func containsConjunction(_ text: String) -> Bool {
        let words = Set(text.split(separator: " ").map(String.init))
        return !words.isDisjoint(with: ["and", "then", "also", "after", "before", "plus", "or", "but", "if", "when"])
    }

    /// The name after one of `verbs`, or nil when the words are anything but `<verb> <name>`.
    private static func name(in text: String, after verbs: [String]) -> String? {
        guard let rest = remainder(of: text, after: verbs) else { return nil }
        let name = stripArticle(rest)
        let words = name.split(separator: " ")
        guard !words.isEmpty, words.count <= maxNameWords else { return nil }
        // A name made only of verbs ("open close") is not a name.
        guard !verbs.contains(name) else { return nil }
        guard words.allSatisfy({ !forbiddenInNames.contains(String($0)) }) else { return nil }
        return name
    }

    private static func stripArticle(_ text: String) -> String {
        for article in ["the ", "my ", "a ", "an "] where text.hasPrefix(article) {
            return String(text.dropFirst(article.count))
        }
        return text
    }

    private static func remainder(of text: String, after verbs: [String]) -> String? {
        for verb in verbs where text.hasPrefix(verb + " ") {
            let rest = String(text.dropFirst(verb.count + 1)).trimmingCharacters(in: .whitespaces)
            guard !rest.isEmpty else { return nil }
            return rest
        }
        return nil
    }

    /// "open google.com", "go to the guardian dot com" — a domain is a target the words
    /// name exactly, so a site command is as deterministic as an app command.
    private static func siteTarget(in text: String) -> String? {
        guard let rest = remainder(of: text, after: siteVerbs) else { return nil }
        // No article stripping here: "the guardian dot com" is theguardian.com, and the
        // "the" is part of the address rather than filler in front of it.
        let candidate = rest
            .replacingOccurrences(of: " dot ", with: ".")
            .replacingOccurrences(of: " ", with: "")
        let parts = candidate.split(separator: ".")
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        guard let tld = parts.last, tld.count >= 2, tld.allSatisfy(\.isLetter) else { return nil }
        return candidate
    }
}

/// Picks the one app a spoken name refers to.
///
/// Exact matches win outright; anything else must be an unambiguous prefix. Two candidates
/// is an ambiguity, and an ambiguous name is not resolved at all — the command goes to the
/// model instead, which is slower and right.
public enum AppNameMatcher {
    public static func match(_ spoken: String, against names: [String]) -> String? {
        let wanted = spoken.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard wanted.count >= 2 else { return nil }
        if let exact = names.first(where: { $0 == wanted }) { return exact }
        let prefixed = names.filter { $0.hasPrefix(wanted) }
        return prefixed.count == 1 ? prefixed[0] : nil
    }
}
