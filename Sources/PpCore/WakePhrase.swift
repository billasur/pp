import Foundation

/// A wake phrase must lead the utterance. Preserve the original command text.
public enum WakePhrase {
    public static func command(in utterance: String, after phrase: String) -> String? {
        func words(_ text: String) -> [(String, Range<String.Index>)] {
            var result: [(String, Range<String.Index>)] = []
            var start: String.Index?
            for index in text.indices {
                if text[index].isLetter || text[index].isNumber {
                    if start == nil { start = index }
                } else if let beginning = start {
                    result.append((String(text[beginning..<index]).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")), beginning..<index))
                    start = nil
                }
            }
            if let start {
                result.append((String(text[start...]).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")), start..<text.endIndex))
            }
            return result
        }
        let expected = words(phrase)
        let spoken = words(utterance)
        guard !expected.isEmpty, !spoken.isEmpty else { return nil }
        let expectedWords = expected.map { $0.0 }
        let allowedFillers: Set<String> = ["ok", "okay", "um", "so", "ah"]
        let maxStartIndex = min(4, spoken.count)
        for i in 0..<maxStartIndex {
            if i > 0 {
                let leadWords = (0..<i).map { spoken[$0].0 }
                if !leadWords.allSatisfy({ allowedFillers.contains($0) }) {
                    continue
                }
            }
            let slice = spoken[i...]
            let sliceWords = slice.map { $0.0 }

            // Exact prefix match
            if sliceWords.count >= expected.count {
                let spokenPrefix = Array(sliceWords.prefix(expected.count))
                let recognizedVariant = (expectedWords == ["hey", "jev"] && spokenPrefix == ["hey", "jeff"])
                    || (expectedWords == ["hey", "pp"] && spokenPrefix == ["ey", "pp"])
                if spokenPrefix == expectedWords || recognizedVariant {
                    let end = slice[slice.startIndex + expected.count - 1].1.upperBound
                    return String(utterance[end...].drop(while: { $0.isWhitespace || ",.:;!?—–-".contains($0) })).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }

            // Handle phonetic split variants for "hey pp" -> "hey p p", "hey pee pee", "ey p p", "ey pee pee"
            if expectedWords == ["hey", "pp"] && sliceWords.count >= 3 {
                let threePrefix = Array(sliceWords.prefix(3))
                if threePrefix == ["hey", "p", "p"] || threePrefix == ["hey", "pee", "pee"]
                    || threePrefix == ["ey", "p", "p"] || threePrefix == ["ey", "pee", "pee"] {
                    let end = slice[slice.startIndex + 2].1.upperBound
                    return String(utterance[end...].drop(while: { $0.isWhitespace || ",.:;!?—–-".contains($0) })).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }

            // Whispered / quiet bare wake at start of utterance: "pp, open Finder" or "p p, open Finder"
            if i == 0 && expectedWords == ["hey", "pp"] && sliceWords.count >= 1 {
                if sliceWords[0] == "pp" {
                    let end = slice[slice.startIndex].1.upperBound
                    return String(utterance[end...].drop(while: { $0.isWhitespace || ",.:;!?—–-".contains($0) })).trimmingCharacters(in: .whitespacesAndNewlines)
                } else if sliceWords.count >= 2 && sliceWords[0] == "p" && sliceWords[1] == "p" {
                    let end = slice[slice.startIndex + 1].1.upperBound
                    return String(utterance[end...].drop(while: { $0.isWhitespace || ",.:;!?—–-".contains($0) })).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }

        return nil
    }
}
