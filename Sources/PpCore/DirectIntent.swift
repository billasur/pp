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
    public static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        let words = lowered.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " .,!?;:"))
    }

    /// Yields normalized tokens alongside their original byte-for-byte Range<String.Index> in text.
    public static func tokenSpans(_ text: String) -> [(token: String, range: Range<String.Index>)] {
        var spans: [(token: String, range: Range<String.Index>)] = []
        var currentIndex = text.startIndex

        while currentIndex < text.endIndex {
            // Skip leading whitespace / punctuation
            while currentIndex < text.endIndex, (text[currentIndex].isWhitespace || ".,!?;:".contains(text[currentIndex])) {
                currentIndex = text.index(after: currentIndex)
            }
            if currentIndex >= text.endIndex { break }

            let tokenStart = currentIndex
            while currentIndex < text.endIndex, !text[currentIndex].isWhitespace, !".,!?;:".contains(text[currentIndex]) {
                currentIndex = text.index(after: currentIndex)
            }
            let tokenEnd = currentIndex
            let rawSub = text[tokenStart..<tokenEnd]
            let normalized = rawSub.lowercased()
            if !normalized.isEmpty {
                spans.append((token: normalized, range: tokenStart..<tokenEnd))
            }
        }
        return spans
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
/// Exact matches win outright; aliases resolve to canonical names; unambiguous prefixes win;
/// spelled-out letters ('z e n') collapse; and safe fuzzy match (edit distance <= 1 for length >= 4)
/// resolves only when exactly one candidate wins. Any ambiguity resolves to nil.
public enum AppNameMatcher {
    public static func match(_ spoken: String, against names: [String]) -> String? {
        var input = spoken.trimmingCharacters(in: .whitespacesAndNewlines)

        // (c) Spelled-out input: collapse single-letter tokens ('z e n' -> 'zen')
        let parts = input.split(separator: " ").map(String.init)
        if parts.count > 1 && parts.allSatisfy({ $0.count == 1 && ($0.first?.isLetter == true || $0.first?.isNumber == true) }) {
            input = parts.joined()
        }

        let wanted = input.lowercased()
        guard wanted.count >= 2 else { return nil }

        // 1. Exact match against candidate names
        if let exact = names.first(where: { $0.lowercased() == wanted }) { return exact }

        // (a) Alias resolution: if alias maps to a name present in candidate names
        if let resolved = AppAliases.shared.resolve(wanted) {
            if let matched = names.first(where: { $0.lowercased() == resolved.lowercased() }) {
                return matched
            }
        }

        // 2. Unambiguous prefix matching
        let prefixed = names.filter { $0.lowercased().hasPrefix(wanted) }
        if prefixed.count == 1 { return prefixed[0] }
        if prefixed.count > 1 { return nil } // Ambiguity must not guess

        // (b) Safe fuzzy matching: edit distance <= 1, only for names >= 4 characters
        if wanted.count >= 4 {
            let fuzzy = names.filter { candidate in
                let candidateLow = candidate.lowercased()
                guard candidateLow.count >= 4 else { return false }
                return editDistance(wanted, candidateLow) <= 1
            }
            if fuzzy.count == 1 { return fuzzy[0] }
            if fuzzy.count > 1 { return nil }
        }

        return nil
    }

    private static func editDistance(_ s1: String, _ s2: String) -> Int {
        let a = Array(s1)
        let b = Array(s2)
        var dist = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { dist[i][0] = i }
        for j in 0...b.count { dist[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                if a[i - 1] == b[j - 1] {
                    dist[i][j] = dist[i - 1][j - 1]
                } else {
                    dist[i][j] = min(dist[i - 1][j] + 1, dist[i][j - 1] + 1, dist[i - 1][j - 1] + 1)
                }
            }
        }
        return dist[a.count][b.count]
    }
}
