import Foundation

/// One inspectable thing pp learned, as shown to the user.
public struct PersonalizationItem: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case macro, alias, contact, prior, menuPath

        public var title: String {
            switch self {
            case .macro: return "Repeated command"
            case .alias: return "App alias"
            case .contact: return "Frequent recipient"
            case .prior: return "Preferred control"
            case .menuPath: return "Menu path"
            }
        }
    }

    public let id: String
    public let kind: Kind
    public var title: String
    public let detail: String
    public var enabled: Bool

    public init(id: String, kind: Kind, title: String, detail: String, enabled: Bool = true) {
        self.id = id; self.kind = kind; self.title = title; self.detail = detail; self.enabled = enabled
    }
}

/// Everything the user can export, and the only shape an import accepts.
public struct PersonalizationBundle: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let macros: [Macro]
    public let features: RankingFeatures
    public let disabledItemIDs: [String]
    public let exportedAt: Date

    public init(version: Int = PersonalizationBundle.currentVersion, macros: [Macro], features: RankingFeatures,
                disabledItemIDs: [String], exportedAt: Date) {
        self.version = version; self.macros = macros; self.features = features
        self.disabledItemIDs = disabledItemIDs; self.exportedAt = exportedAt
    }
}

public enum PersonalizationError: LocalizedError, Equatable {
    case unknownItem(String)
    case emptyTitle
    case unsupportedBundle(Int)

    public var errorDescription: String? {
        switch self {
        case .unknownItem(let id): return "There is nothing learned with the id \(id)."
        case .emptyTitle: return "A name is required."
        case .unsupportedBundle(let version): return "That export was written by a different version of pp (bundle \(version))."
        }
    }
}

/// Inspect, rename, disable, export and delete everything pp learned.
///
/// Every learned item is visible here by construction: if it is not in `items()`, it is
/// not stored anywhere, so "delete" really means delete.
public final class PersonalizationStore: @unchecked Sendable {
    private let lock = NSLock()
    private let macros: MacroLibrary
    private let ranking: RankingModel
    private var disabledItemIDs: Set<String> = []
    private var titleOverrides: [String: String] = [:]

    public init(macros: MacroLibrary, ranking: RankingModel) {
        self.macros = macros
        self.ranking = ranking
    }

    public func items() -> [PersonalizationItem] {
        lock.lock()
        let disabled = disabledItemIDs
        let titles = titleOverrides
        lock.unlock()

        let features = ranking.features
        var result: [PersonalizationItem] = []

        for macro in macros.all() {
            result.append(PersonalizationItem(
                id: macro.id, kind: .macro,
                title: titles[macro.id] ?? macro.name,
                detail: "\(macro.steps.count) steps, used \(macro.successCount) times",
                enabled: macro.enabled && !disabled.contains(macro.id)))
        }
        for (key, value) in features.appAliases.sorted(by: { $0.key < $1.key }) {
            let id = "alias:\(key)"
            result.append(PersonalizationItem(id: id, kind: .alias, title: titles[id] ?? "\(key) → \(value)",
                                              detail: "Spoken name resolved to an app", enabled: !disabled.contains(id)))
        }
        for (name, count) in features.frequentContacts.sorted(by: { $0.value > $1.value }) {
            let id = "contact:\(name)"
            result.append(PersonalizationItem(id: id, kind: .contact, title: titles[id] ?? name,
                                              detail: "Recipient \(count) times", enabled: !disabled.contains(id)))
        }
        for (key, count) in features.successfulTargets.sorted(by: { $0.key < $1.key }) {
            let id = "prior:\(key)"
            result.append(PersonalizationItem(id: id, kind: .prior, title: titles[id] ?? key,
                                              detail: "Preferred \(count) times", enabled: !disabled.contains(id)))
        }
        for (key, path) in features.menuPaths.sorted(by: { $0.key < $1.key }) {
            let id = "menu:\(key)"
            result.append(PersonalizationItem(id: id, kind: .menuPath, title: titles[id] ?? key,
                                              detail: path.joined(separator: " ▸ "), enabled: !disabled.contains(id)))
        }
        return result
    }

    public func rename(id: String, to title: String) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PersonalizationError.emptyTitle }
        guard items().contains(where: { $0.id == id }) else { throw PersonalizationError.unknownItem(id) }
        lock.lock(); defer { lock.unlock() }
        titleOverrides[id] = trimmed
    }

    public func setEnabled(id: String, enabled: Bool) throws {
        guard items().contains(where: { $0.id == id }) else { throw PersonalizationError.unknownItem(id) }
        lock.lock()
        if enabled { disabledItemIDs.remove(id) } else { disabledItemIDs.insert(id) }
        lock.unlock()

        // A macro is the one kind pp acts on directly, so disabling it must actually
        // stop it being used, not just grey it out in the list.
        if id.count == 16, let macro = macros.all().first(where: { $0.id == id }) {
            var updated = macro
            updated.enabled = enabled
            macros.insert(updated)
        }
    }

    public func delete(id: String) throws {
        guard let item = items().first(where: { $0.id == id }) else { throw PersonalizationError.unknownItem(id) }
        switch item.kind {
        case .macro:
            macros.remove(id: id)
        case .alias:
            var features = ranking.features
            features.appAliases.removeValue(forKey: id.replacingOccurrences(of: "alias:", with: ""))
            ranking.replaceFeatures(features)
        case .contact:
            var features = ranking.features
            features.frequentContacts.removeValue(forKey: id.replacingOccurrences(of: "contact:", with: ""))
            ranking.replaceFeatures(features)
        case .prior:
            var features = ranking.features
            features.successfulTargets.removeValue(forKey: id.replacingOccurrences(of: "prior:", with: ""))
            ranking.replaceFeatures(features)
        case .menuPath:
            var features = ranking.features
            features.menuPaths.removeValue(forKey: id.replacingOccurrences(of: "menu:", with: ""))
            ranking.replaceFeatures(features)
        }
        lock.lock(); disabledItemIDs.remove(id); titleOverrides.removeValue(forKey: id); lock.unlock()
    }

    /// Removes every trace, in every store.
    public func deleteEverything() {
        macros.replaceAll([])
        ranking.replaceFeatures(RankingFeatures())
        lock.lock()
        disabledItemIDs.removeAll()
        titleOverrides.removeAll()
        lock.unlock()
    }

    public func export() throws -> Data {
        let bundle = PersonalizationBundle(
            macros: macros.all(),
            features: ranking.features,
            disabledItemIDs: Array(lock.withLockItems(disabledItemIDs)).sorted(),
            exportedAt: Date())
        return try PpJSON.encoder(pretty: true).encode(bundle)
    }

    public func importBundle(_ data: Data) throws {
        let bundle = try PpJSON.decoder().decode(PersonalizationBundle.self, from: data)
        guard bundle.version <= PersonalizationBundle.currentVersion else {
            throw PersonalizationError.unsupportedBundle(bundle.version)
        }
        macros.replaceAll(bundle.macros)
        ranking.replaceFeatures(bundle.features)
        lock.lock()
        disabledItemIDs = Set(bundle.disabledItemIDs)
        lock.unlock()
    }
}

private extension NSLock {
    func withLockItems<T>(_ value: T) -> T {
        lock(); defer { unlock() }
        return value
    }
}
