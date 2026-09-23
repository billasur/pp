import Foundation

/// Canonical hosts and search templates for common web sites.
public struct SiteEntry: Sendable {
    public let name: String
    public let canonicalHost: String
    public let searchTemplate: String
    public let playTemplate: String?

    public init(name: String, canonicalHost: String, searchTemplate: String, playTemplate: String? = nil) {
        self.name = name
        self.canonicalHost = canonicalHost
        self.searchTemplate = searchTemplate
        self.playTemplate = playTemplate
    }

    public func searchURL(for query: String) -> URL? {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        let urlString = searchTemplate.replacingOccurrences(of: "{q}", with: encoded)
        return URL(string: urlString)
    }

    public func playURL(for query: String) -> URL? {
        let template = playTemplate ?? searchTemplate
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        let urlString = template.replacingOccurrences(of: "{q}", with: encoded)
        return URL(string: urlString)
    }
}

public enum SiteTable {
    private static let entries: [String: SiteEntry] = [
        "youtube": SiteEntry(
            name: "YouTube",
            canonicalHost: "youtube.com",
            searchTemplate: "https://www.youtube.com/results?search_query={q}",
            playTemplate: "https://www.youtube.com/results?search_query={q}"
        ),
        "google": SiteEntry(
            name: "Google",
            canonicalHost: "google.com",
            searchTemplate: "https://www.google.com/search?q={q}"
        ),
        "github": SiteEntry(
            name: "GitHub",
            canonicalHost: "github.com",
            searchTemplate: "https://github.com/search?q={q}"
        ),
        "wikipedia": SiteEntry(
            name: "Wikipedia",
            canonicalHost: "wikipedia.org",
            searchTemplate: "https://en.wikipedia.org/wiki/Special:Search?search={q}"
        ),
        "maps": SiteEntry(
            name: "Google Maps",
            canonicalHost: "maps.google.com",
            searchTemplate: "https://www.google.com/maps/search/{q}"
        ),
        "google maps": SiteEntry(
            name: "Google Maps",
            canonicalHost: "maps.google.com",
            searchTemplate: "https://www.google.com/maps/search/{q}"
        ),
        "amazon": SiteEntry(
            name: "Amazon",
            canonicalHost: "amazon.com",
            searchTemplate: "https://www.amazon.com/s?k={q}"
        ),
        "reddit": SiteEntry(
            name: "Reddit",
            canonicalHost: "reddit.com",
            searchTemplate: "https://www.reddit.com/search/?q={q}"
        ),
        "stackoverflow": SiteEntry(
            name: "Stack Overflow",
            canonicalHost: "stackoverflow.com",
            searchTemplate: "https://stackoverflow.com/search?q={q}"
        ),
        "stack overflow": SiteEntry(
            name: "Stack Overflow",
            canonicalHost: "stackoverflow.com",
            searchTemplate: "https://stackoverflow.com/search?q={q}"
        ),
        "x": SiteEntry(
            name: "X",
            canonicalHost: "x.com",
            searchTemplate: "https://x.com/search?q={q}"
        ),
        "twitter": SiteEntry(
            name: "Twitter",
            canonicalHost: "x.com",
            searchTemplate: "https://x.com/search?q={q}"
        ),
        "spotify": SiteEntry(
            name: "Spotify",
            canonicalHost: "spotify.com",
            searchTemplate: "https://open.spotify.com/search/{q}",
            playTemplate: "https://open.spotify.com/search/{q}"
        ),
        "linkedin": SiteEntry(
            name: "LinkedIn",
            canonicalHost: "linkedin.com",
            searchTemplate: "https://www.linkedin.com/search/results/all/?keywords={q}"
        ),
        "chatgpt": SiteEntry(
            name: "ChatGPT",
            canonicalHost: "chatgpt.com",
            searchTemplate: "https://chatgpt.com/?q={q}"
        ),
        "perplexity": SiteEntry(
            name: "Perplexity",
            canonicalHost: "perplexity.ai",
            searchTemplate: "https://www.perplexity.ai/search?q={q}"
        )
    ]

    public static func entry(named name: String) -> SiteEntry? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let direct = entries[key] { return direct }
        for (_, v) in entries {
            if v.canonicalHost.lowercased() == key || v.name.lowercased() == key {
                return v
            }
        }
        return nil
    }

    public static func searchURL(for query: String, on siteName: String?) -> URL? {
        if let siteName, let site = entry(named: siteName) {
            return site.searchURL(for: query)
        }
        return entries["google"]?.searchURL(for: query)
    }

    public static func playURL(for query: String, on siteName: String = "youtube") -> URL? {
        let site = entry(named: siteName) ?? entries["youtube"]!
        return site.playURL(for: query)
    }

    public static func isKnownSite(_ name: String) -> Bool {
        return entry(named: name) != nil
    }
}
