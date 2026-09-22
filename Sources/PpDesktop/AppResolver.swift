import AppKit
import PpCore

/// Finds the app a name refers to, without reading the screen.
///
/// This is what makes "open Notes" finish while the user is still speaking: by the time
/// the sentence closes, the app is already resolved, so only the launch is left. The answer
/// is cached for a moment, because a folder listing of every installed app is not something
/// to repeat on every partial transcript.
@MainActor
enum AppResolver {
    struct Resolved {
        let name: String
        let url: URL
        let running: NSRunningApplication?
    }

    private static var cache: (built: Date, apps: [(name: String, file: String, url: URL)])?
    private static let lifetime: TimeInterval = 60

    /// The app whose name matches, or the one whose name starts with it when exactly one
    /// does. Two candidates is an ambiguity, and an ambiguous name goes back to the model.
    static func resolve(_ spoken: String) -> Resolved? {
        let wanted = spoken.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard wanted.count >= 2 else { return nil }

        if let running = runningMatch(wanted) {
            guard let url = running.bundleURL else { return nil }
            return Resolved(name: running.localizedName ?? wanted, url: url, running: running)
        }
        let installed = installedApps()
        guard let matched = AppNameMatcher.match(wanted, against: installed.map(\.name)),
              let only = installed.first(where: { $0.name == matched }) else { return nil }
        return Resolved(name: only.file, url: only.url, running: nil)
    }

    private static func runningMatch(_ wanted: String) -> NSRunningApplication? {
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        func name(_ app: NSRunningApplication) -> String {
            (app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? "").lowercased()
        }
        guard let matched = AppNameMatcher.match(wanted, against: running.map(name)) else { return nil }
        return running.first { name($0) == matched }
    }

    /// Every installed app, by display name and by bundle file name.
    private static func installedApps() -> [(name: String, file: String, url: URL)] {
        if let cache, Date().timeIntervalSince(cache.built) < lifetime { return cache.apps }

        let fm = FileManager.default
        let roots = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                     "/System/Library/CoreServices",
                     fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        var found: [(name: String, file: String, url: URL)] = []
        var seen = Set<String>()
        for root in roots {
            let entries = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil)) ?? []
            for url in entries where url.pathExtension == "app" {
                guard seen.insert(url.path).inserted else { continue }
                let file = url.deletingPathExtension().lastPathComponent
                let display = (Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? file
                found.append((display.lowercased(), file.lowercased(), url))
            }
        }
        cache = (Date(), found)
        return found
    }
}
