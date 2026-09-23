import Foundation

/// Match result indicating the command remainder and exact character range of the wake phrase.
public struct WakeMatch: Equatable, Sendable {
    public let command: String
    public let matchedRange: Range<String.Index>

    public init(command: String, matchedRange: Range<String.Index>) {
        self.command = command
        self.matchedRange = matchedRange
    }
}

/// Robust, vocabulary-biased wake matcher for "Hey pp".
///
/// Handles ASR variations (e.g. "ey pp", "heipp", "hey p p", "hey bee", "hey papa", "a pp"),
/// collapsed doubled letters, 1-edit distance on the second token, and merges in the first 4 tokens.
public enum WakeMatcher {
    private static let word1Candidates: Set<String> = [
        "hey", "hei", "he", "ey", "a", "hay", "hi", "ay"
    ]

    private static let word2Candidates: Set<String> = [
        "pp", "p", "pee", "peepee", "peep", "peepy", "pip", "pop", "papa", "bee"
    ]

    private static let mergedCandidates: Set<String> = [
        "heypp", "heipp", "aip", "heypee", "haypp", "hipp", "hype", "heyp", "hepp", "aypp"
    ]

    public static func match(in utterance: String) -> WakeMatch? {
        struct Token {
            let original: String
            let normalized: String
            let collapsed: String
            let range: Range<String.Index>
        }

        func tokenize(_ text: String) -> [Token] {
            var tokens: [Token] = []
            var start: String.Index?
            for idx in text.indices {
                let ch = text[idx]
                if ch.isLetter || ch.isNumber {
                    if start == nil { start = idx }
                } else if let beginning = start {
                    let word = String(text[beginning..<idx])
                    let norm = normalize(word, maxRepeats: 2)
                    let col = normalize(word, maxRepeats: 1)
                    tokens.append(Token(original: word, normalized: norm, collapsed: col, range: beginning..<idx))
                    start = nil
                }
            }
            if let beginning = start {
                let word = String(text[beginning...])
                let norm = normalize(word, maxRepeats: 2)
                let col = normalize(word, maxRepeats: 1)
                tokens.append(Token(original: word, normalized: norm, collapsed: col, range: beginning..<text.endIndex))
            }
            return tokens
        }

        let tokens = tokenize(utterance)
        guard !tokens.isEmpty else { return nil }

        let searchLimit = min(4, tokens.count)

        for i in 0..<searchLimit {
            let tok = tokens[i]

            // 1. Single-token merges (e.g. "heypp", "heipp", "aip")
            if mergedCandidates.contains(tok.normalized) || mergedCandidates.contains(tok.collapsed) {
                let range = tok.range
                let remainder = extractRemainder(from: utterance, after: range.upperBound)
                return WakeMatch(command: remainder, matchedRange: range)
            }

            // 2. Whispered / quiet bare wake at start of utterance ("pp", "p p")
            if i == 0 {
                if tok.normalized == "pp" || tok.original.lowercased() == "pp" {
                    let range = tok.range
                    let remainder = extractRemainder(from: utterance, after: range.upperBound)
                    return WakeMatch(command: remainder, matchedRange: range)
                }
                if tokens.count >= 2 && tokens[0].normalized == "p" && tokens[1].normalized == "p" {
                    let range = tokens[0].range.lowerBound..<tokens[1].range.upperBound
                    let remainder = extractRemainder(from: utterance, after: range.upperBound)
                    return WakeMatch(command: remainder, matchedRange: range)
                }
            }

            // 3. Two-word match (word 1 + word 2)
            let isWord1 = word1Candidates.contains(tok.normalized) || word1Candidates.contains(tok.collapsed)
            if isWord1 && i + 1 < tokens.count {
                let nextTok = tokens[i + 1]

                // Check 3-token split e.g. "hey p p" or "hey pee pee"
                if i + 2 < tokens.count {
                    let tok3 = tokens[i + 2]
                    let pair = [nextTok.normalized, tok3.normalized]
                    if pair == ["p", "p"] || pair == ["pee", "pee"] || pair == ["pe", "pe"] {
                        let range = tok.range.lowerBound..<tok3.range.upperBound
                        let remainder = extractRemainder(from: utterance, after: range.upperBound)
                        return WakeMatch(command: remainder, matchedRange: range)
                    }
                }

                // Check 2-token match
                if isWord2Match(nextTok.normalized) || isWord2Match(nextTok.collapsed) {
                    let range = tok.range.lowerBound..<nextTok.range.upperBound
                    let remainder = extractRemainder(from: utterance, after: range.upperBound)
                    return WakeMatch(command: remainder, matchedRange: range)
                }
            }
        }

        return nil
    }

    private static func isWord2Match(_ norm: String) -> Bool {
        if word2Candidates.contains(norm) {
            return true
        }
        // One edit distance to "pp" or "pee"
        if norm.count >= 2 && (editDistance(norm, "pp") <= 1 || editDistance(norm, "pee") <= 1) {
            return true
        }
        return false
    }

    private static func normalize(_ s: String, maxRepeats: Int) -> String {
        let lowered = s.lowercased()
        var result = ""
        var count = 0
        var prev: Character?
        for ch in lowered {
            guard ch.isLetter || ch.isNumber else { continue }
            if ch == prev {
                count += 1
                if count <= maxRepeats {
                    result.append(ch)
                }
            } else {
                prev = ch
                count = 1
                result.append(ch)
            }
        }
        return result
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

    private static func extractRemainder(from utterance: String, after index: String.Index) -> String {
        let remainderSlice = utterance[index...]
        return String(remainderSlice.drop(while: { $0.isWhitespace || ",.:;!?—–-".contains($0) }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
