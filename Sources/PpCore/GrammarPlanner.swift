import Foundation

/// Deterministic, fast, 100% offline rule-based planner for decomposing spoken commands into ordered `[PlanStep]`s.
public enum GrammarPlanner {
    public static func plan(
        utterance: String,
        frontApp: String = "",
        runningApps: [String] = []
    ) -> [PlanStep] {
        let trimmed = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // 1. Check for compound connective phrases
        let clauses = splitCompoundUtterance(trimmed)
        if clauses.count > 1 {
            var steps: [PlanStep] = []
            for clause in clauses {
                let parsed = parseClause(clause, frontApp: frontApp)
                steps.append(contentsOf: parsed)
            }
            if !steps.isEmpty {
                return steps
            }
        }

        // 2. Parse as a single clause
        return parseClause(trimmed, frontApp: frontApp)
    }

    /// Splits an utterance on sequence markers like "and then", "then", "after that", etc.
    public static func splitCompoundUtterance(_ text: String) -> [String] {
        let markers = [
            " and then ",
            " then ",
            " after that ",
            " and also ",
            "; "
        ]

        var segments = [text]
        for marker in markers {
            var next: [String] = []
            for seg in segments {
                let parts = seg.components(separatedBy: marker)
                for p in parts {
                    let t = p.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { next.append(t) }
                }
            }
            segments = next
        }

        // Also check for "and" when joining two verb clauses (e.g. "open Safari and search for cats")
        var finalSegments: [String] = []
        for seg in segments {
            if let andSplit = splitOnVerbConjunction(seg) {
                finalSegments.append(contentsOf: andSplit)
            } else {
                finalSegments.append(seg)
            }
        }

        return finalSegments
    }

    private static let actionVerbs = [
        "open", "launch", "start", "switch to", "go to", "visit", "browse to",
        "search for", "search", "google", "type", "enter", "write", "input",
        "run", "press", "hit", "click", "tap", "close", "quit", "scroll",
        "save", "new tab"
    ]

    private static func splitOnVerbConjunction(_ text: String) -> [String]? {
        let lower = text.lowercased()
        let delimiter = " and "
        guard let range = lower.range(of: delimiter) else { return nil }

        let firstPart = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let secondPart = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)

        let secondLower = secondPart.lowercased()
        let startsWithVerb = actionVerbs.contains { secondLower.hasPrefix($0 + " ") || secondLower == $0 }

        if startsWithVerb && !firstPart.isEmpty {
            return [firstPart, secondPart]
        }
        return nil
    }

    /// Parses an atomic action clause into one or more PlanSteps.
    public static func parseClause(_ clause: String, frontApp: String) -> [PlanStep] {
        let trimmed = clause.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        // 1. Search commands ("search for X", "google X")
        if let searchMatch = matchPrefix(lower, prefixes: ["search for ", "search ", "google "]) {
            let query = String(trimmed.dropFirst(searchMatch.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return [
                PlanStep(kind: .openURL, target: "https://www.google.com/search?q=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)"),
                PlanStep(kind: .focusInput, target: "Search input"),
                PlanStep(kind: .typeText, target: "Search input", text: query)
            ]
        }

        // 2. Terminal commands ("run X")
        if lower.hasPrefix("run ") {
            let cmd = String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
            return [
                PlanStep(kind: .openApp, target: "Terminal"),
                PlanStep(kind: .typeText, target: "Terminal", text: cmd),
                PlanStep(kind: .pressKey, target: "return")
            ]
        }

        // 3. Web Navigation ("go to X", "visit X", "browse to X")
        if let navMatch = matchPrefix(lower, prefixes: ["go to ", "visit ", "browse to "]) {
            let target = String(trimmed.dropFirst(navMatch.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            let url = sanitizeURL(target)
            return [PlanStep(kind: .openURL, target: url)]
        }

        // 4. Open App / Folder / URL ("open X", "launch X", "start X", "switch to X")
        if let openMatch = matchPrefix(lower, prefixes: ["open ", "launch ", "start ", "switch to "]) {
            let target = String(trimmed.dropFirst(openMatch.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanTarget = target.replacingOccurrences(of: " app$", with: "", options: .regularExpression)
                                    .replacingOccurrences(of: " application$", with: "", options: .regularExpression)
            let lowerTarget = cleanTarget.lowercased()

            // Check if folder
            let commonFolders = ["downloads", "documents", "desktop", "projects", "pictures", "movies", "music", "home"]
            if commonFolders.contains(lowerTarget) || lowerTarget.hasSuffix(" folder") {
                let folderName = cleanTarget.replacingOccurrences(of: " folder$", with: "", options: .regularExpression)
                return [PlanStep(kind: .openFolder, target: folderName.capitalized)]
            }

            // Check if web address
            if isWebAddress(cleanTarget) {
                return [PlanStep(kind: .openURL, target: sanitizeURL(cleanTarget))]
            }

            // Otherwise, open app
            return [PlanStep(kind: .openApp, target: cleanTarget)]
        }

        // 5. Type text ("type X", "enter X", "write X")
        if let typeMatch = matchPrefix(lower, prefixes: ["type ", "enter ", "write ", "input "]) {
            let rest = String(trimmed.dropFirst(typeMatch.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            // Check for "type X in/into Y"
            let inPattern = "(?i)^[\"']?(.+?)[\"']?\\s+(?:in|into)\\s+(.+)$"
            if let regex = try? NSRegularExpression(pattern: inPattern),
               let match = regex.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)) {
                let textRange = Range(match.range(at: 1), in: rest)!
                let targetRange = Range(match.range(at: 2), in: rest)!
                let text = String(rest[textRange])
                let targetInput = String(rest[targetRange])
                return [
                    PlanStep(kind: .focusInput, target: targetInput),
                    PlanStep(kind: .typeText, target: targetInput, text: text)
                ]
            }

            let text = rest.trimmingCharacters(in: CharacterSet(charactersIn: "\"\'"))
            return [PlanStep(kind: .typeText, target: nil, text: text)]
        }

        // 6. Press key ("press return", "hit enter")
        if let keyMatch = matchPrefix(lower, prefixes: ["press ", "hit "]) {
            let key = String(trimmed.dropFirst(keyMatch.count)).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let validKeys = ["return", "enter", "space", "escape", "esc", "tab", "up", "down", "left", "right"]
            if validKeys.contains(key) {
                let mappedKey = (key == "enter") ? "return" : ((key == "esc") ? "escape" : key)
                return [PlanStep(kind: .pressKey, target: mappedKey)]
            }
        }

        // 7. Menu / Window controls
        if lower == "close window" || lower == "close the window" || lower == "close this window" || lower == "close it" {
            return [PlanStep(kind: .menu, target: "Close Window")]
        }
        if lower == "new tab" || lower == "open a new tab" || lower == "new tab please" {
            return [PlanStep(kind: .menu, target: "New Tab")]
        }
        if lower == "save" || lower == "save file" || lower == "save the file" || lower == "save it" {
            return [PlanStep(kind: .menu, target: "Save")]
        }

        // 8. Quit / Close App ("quit Slack", "close Finder")
        if let quitMatch = matchPrefix(lower, prefixes: ["quit ", "close app ", "exit "]) {
            let target = String(trimmed.dropFirst(quitMatch.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return [PlanStep(kind: .quitApp, target: target)]
        }

        // 9. Scrolling ("scroll down 3 times", "scroll up")
        if lower.hasPrefix("scroll ") {
            let rest = String(lower.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
            let isUp = rest.hasPrefix("up")
            let dir = isUp ? "up" : "down"
            let numPattern = "(\\d+)"
            var amount: Int? = nil
            if let numRegex = try? NSRegularExpression(pattern: numPattern),
               let match = numRegex.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)) {
                let range = Range(match.range(at: 1), in: rest)!
                amount = Int(rest[range])
            }
            return [PlanStep(kind: .scroll, target: dir, amount: amount)]
        }

        // 10. Clicking / Tapping ("click Search button", "click on Submit")
        if let clickMatch = matchPrefix(lower, prefixes: ["click on ", "click ", "tap on ", "tap "]) {
            let target = String(trimmed.dropFirst(clickMatch.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            let clean = target.replacingOccurrences(of: "^the\\s+", with: "", options: .regularExpression)
            return [PlanStep(kind: .click, target: clean)]
        }

        // Default fallback: Single click or interactive step for Laya to ground
        return [PlanStep(kind: .click, target: trimmed)]
    }

    private static func matchPrefix(_ text: String, prefixes: [String]) -> String? {
        for p in prefixes {
            if text.hasPrefix(p) { return p }
        }
        return nil
    }

    private static func isWebAddress(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return true }
        let domains = [".com", ".org", ".net", ".io", ".ai", ".co", ".app", ".dev", ".edu", ".gov"]
        for d in domains {
            if lower.contains(d) { return true }
        }
        return false
    }

    private static func sanitizeURL(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            return trimmed
        }
        return "https://" + trimmed
    }
}
