import Foundation

/// Manages built-in and user-customised application name aliases.
public final class AppAliases: @unchecked Sendable {
    public static let shared = AppAliases()

    private let lock = NSLock()
    private var userAliases: [String: String] = [:]

    public static let builtIn: [String: String] = [
        "zen": "Zen",
        "chrome": "Google Chrome",
        "google chrome": "Google Chrome",
        "code": "Visual Studio Code",
        "vs code": "Visual Studio Code",
        "vscode": "Visual Studio Code",
        "whatsapp": "WhatsApp",
        "messages": "Messages",
        "imessage": "Messages",
        "terminal": "Terminal",
        "iterm": "iTerm",
        "notes": "Notes",
        "finder": "Finder",
        "safari": "Safari",
        "photos": "Photos",
        "music": "Music",
        "calendar": "Calendar",
        "mail": "Mail",
        "system settings": "System Settings",
        "settings": "System Settings"
    ]

    public init(userAliases: [String: String] = [:]) {
        self.userAliases = userAliases
    }

    public func resolve(_ name: String) -> String? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        lock.lock()
        defer { lock.unlock() }
        if let custom = userAliases[key] {
            return custom
        }
        return Self.builtIn[key]
    }

    public func setUserAlias(alias: String, target: String) {
        lock.lock()
        defer { lock.unlock() }
        userAliases[alias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] = target
    }

    public func removeUserAlias(alias: String) {
        lock.lock()
        defer { lock.unlock() }
        userAliases.removeValue(forKey: alias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    public var allAliases: [String] {
        lock.lock()
        defer { lock.unlock() }
        var set = Set(Self.builtIn.keys)
        for k in userAliases.keys { set.insert(k) }
        return Array(set).sorted()
    }
}
