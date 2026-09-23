import Foundation

/// User preferences for web browsing and search.
public final class Preferences: @unchecked Sendable {
    public static let shared = Preferences()

    private let lock = NSLock()
    private let browserKey = "PreferredBrowser"
    private let searchEngineKey = "PreferredSearchEngine"

    public init() {}

    /// Preferred browser application name (e.g. "Zen", "Google Chrome", "Safari", or nil for system default).
    public var preferredBrowser: String? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return UserDefaults.standard.string(forKey: browserKey)
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: browserKey)
            } else {
                UserDefaults.standard.removeObject(forKey: browserKey)
            }
        }
    }

    /// Preferred search engine name (default: "google").
    public var preferredSearchEngine: String {
        get {
            lock.lock()
            defer { lock.unlock() }
            return UserDefaults.standard.string(forKey: searchEngineKey) ?? "google"
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            UserDefaults.standard.set(newValue, forKey: searchEngineKey)
        }
    }
}
