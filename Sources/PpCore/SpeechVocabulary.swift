import Foundation

/// Builds a curated contextual vocabulary biased for speech recognition.
public final class SpeechVocabulary: @unchecked Sendable {
    public static let shared = SpeechVocabulary()

    private let lock = NSLock()
    private var customApps: [String] = []
    private var frequentContacts: [String] = []

    public static let wakePhrases: [String] = [
        "Hey pp", "hey pp", "Hey peep", "Hey pee pee", "heipp", "heypp", "ey pp", "hey p p"
    ]

    public static let commonSites: [String] = [
        "YouTube", "Google", "GitHub", "Wikipedia", "WhatsApp", "Spotify",
        "Google Maps", "Reddit", "Twitter", "X", "ChatGPT", "Perplexity"
    ]

    public static let commonVerbs: [String] = [
        "open", "launch", "quit", "close", "search for", "search",
        "set an alarm", "set a timer", "cancel", "snooze", "quiet",
        "message", "text", "send", "play", "turn up", "turn down", "mute"
    ]

    public init() {}

    public func setCustomApps(_ apps: [String]) {
        lock.lock()
        defer { lock.unlock() }
        self.customApps = apps
    }

    public func setFrequentContacts(_ contacts: [String]) {
        lock.lock()
        defer { lock.unlock() }
        self.frequentContacts = contacts
    }

    /// Curated list of 60–120 strings for SFSpeechRecognitionRequest.contextualStrings.
    public func commandStrings() -> [String] {
        lock.lock()
        defer { lock.unlock() }

        var result: [String] = []
        var seen = Set<String>()

        func add(_ items: [String]) {
            for item in items {
                let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let lower = trimmed.lowercased()
                if !seen.contains(lower) {
                    seen.insert(lower)
                    result.append(trimmed)
                }
            }
        }

        add(Self.wakePhrases)
        add(AppAliases.shared.allAliases)
        add(customApps)
        add(Self.commonSites)
        add(frequentContacts)
        add(Self.commonVerbs)

        // Cap to 120 most relevant items
        if result.count > 120 {
            return Array(result.prefix(120))
        }
        return result
    }
}
