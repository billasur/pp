import Foundation

/// Web-specific intents parsed from spoken commands.
public enum WebIntent: Equatable, Sendable {
    case openSite(host: String)
    case search(query: String, site: String?)
    case play(query: String, site: String)
    case none

    public var url: URL? {
        switch self {
        case .openSite(let host):
            let normalized = host.hasPrefix("http://") || host.hasPrefix("https://") ? host : "https://\(host)"
            return URL(string: normalized)
        case .search(let query, let site):
            return SiteTable.searchURL(for: query, on: site)
        case .play(let query, let site):
            return SiteTable.playURL(for: query, on: site)
        case .none:
            return nil
        }
    }
}

public enum WebIntentParser {
    private static let domainTlds: Set<String> = [
        "com", "org", "net", "io", "ai", "dev", "app", "co", "edu", "gov",
        "me", "info", "xyz", "uk", "de", "ca", "jp", "fr", "in", "tv", "fm"
    ]

    public static func isDomain(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return true
        }
        let parts = trimmed.split(separator: ".")
        guard parts.count >= 2, let tld = parts.last else { return false }
        // Must not contain spaces and must have a recognized or valid-looking TLD
        if trimmed.contains(" ") { return false }
        return domainTlds.contains(String(tld)) || (tld.count >= 2 && tld.allSatisfy(\.isLetter))
    }

    public static func parse(_ text: String) -> WebIntent {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:\"'"))
        guard !trimmed.isEmpty else { return .none }
        let lower = trimmed.lowercased()

        // (f) Bare domain with no verb (e.g. "youtube.com", "github.com")
        if isDomain(lower) {
            return .openSite(host: lower)
        }

        // (a) open | go to | visit <domain>
        for prefix in ["open ", "go to ", "visit "] {
            if lower.hasPrefix(prefix) {
                let rest = String(lower.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if isDomain(rest) {
                    return .openSite(host: rest)
                }
            }
        }

        // (e) play <query> on <site>
        if lower.hasPrefix("play ") {
            let rest = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
            let lowerRest = rest.lowercased()
            if let onRange = lowerRest.range(of: " on ", options: .backwards) {
                let query = String(rest[..<onRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let site = String(lowerRest[onRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !query.isEmpty && !site.isEmpty && (SiteTable.isKnownSite(site) || isDomain(site)) {
                    return .play(query: query, site: site)
                }
            }
        }

        // (c) search <domain> where the argument is a bare domain (e.g. "search youtube.com")
        if lower.hasPrefix("search ") {
            let rest = String(lower.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
            if isDomain(rest) {
                return .openSite(host: rest)
            }
        }

        // (b) search <site> for <query>
        if lower.hasPrefix("search ") {
            let rest = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
            let lowerRest = rest.lowercased()
            if let forRange = lowerRest.range(of: " for ") {
                let potentialSite = String(lowerRest[..<forRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let query = String(rest[forRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if SiteTable.isKnownSite(potentialSite) {
                    return .search(query: query, site: potentialSite)
                } else if isDomain(potentialSite) {
                    return .search(query: query, site: potentialSite)
                } else {
                    // e.g. "search my email for the invoice" -> NOT a web site search!
                    return .none
                }
            }
        }

        // (d) search for <query>
        if lower.hasPrefix("search for ") {
            let query = String(trimmed.dropFirst(11)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !query.isEmpty {
                return .search(query: query, site: nil)
            }
        }

        // (d) google <query>
        if lower.hasPrefix("google ") {
            let query = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !query.isEmpty {
                return .search(query: query, site: "google")
            }
        }

        return .none
    }
}
