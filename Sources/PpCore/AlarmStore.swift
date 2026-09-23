import Foundation

public struct ScheduledItem: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case alarm
        case timer
    }

    public let id: String
    public let kind: Kind
    public let label: String
    public let targetDate: Date
    public let createdAt: Date

    public init(id: String = UUID().uuidString, kind: Kind, label: String, targetDate: Date, createdAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.label = label
        self.targetDate = targetDate
        self.createdAt = createdAt
    }
}

public actor AlarmStore {
    private let fileURL: URL
    private var items: [ScheduledItem] = []

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let ppDir = appSupport.appendingPathComponent("pp", isDirectory: true)
            try? FileManager.default.createDirectory(at: ppDir, withIntermediateDirectories: true)
            self.fileURL = ppDir.appendingPathComponent("alarms.json")
        }
    }

    public func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            items = []
            return
        }
        do {
            items = try PpJSON.decoder().decode([ScheduledItem].self, from: data)
        } catch {
            items = []
        }
    }

    public func save() {
        do {
            let data = try PpJSON.encoder(pretty: true).encode(items)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Log or ignore error
        }
    }

    public func add(_ item: ScheduledItem) {
        items.removeAll(where: { $0.id == item.id })
        items.append(item)
        items.sort(by: { $0.targetDate < $1.targetDate })
        save()
    }

    public func cancel(id: String) -> ScheduledItem? {
        if let index = items.firstIndex(where: { $0.id == id }) {
            let removed = items.remove(at: index)
            save()
            return removed
        }
        return nil
    }

    public func cancelMatching(target: String?) -> [ScheduledItem] {
        if let target = target?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines), !target.isEmpty {
            let matching = items.filter { $0.label.lowercased().contains(target) || $0.id.hasPrefix(target) }
            items.removeAll(where: { matching.contains($0) })
            save()
            return matching
        } else {
            // Cancel next upcoming
            if !items.isEmpty {
                let removed = items.removeFirst()
                save()
                return [removed]
            }
            return []
        }
    }

    public func next(after date: Date = Date()) -> ScheduledItem? {
        items.first(where: { $0.targetDate > date })
    }

    public func all() -> [ScheduledItem] {
        items
    }

    public func cleanExpired(before date: Date = Date()) {
        items.removeAll(where: { $0.targetDate <= date })
        save()
    }

    public func markFired(id: String) {
        items.removeAll(where: { $0.id == id })
        save()
    }

    public func prunePastNonRepeating(now: Date = Date()) {
        cleanExpired(before: now)
    }

    public func nextFireDate(after date: Date = Date()) -> Date? {
        items.first(where: { $0.targetDate > date })?.targetDate
    }
}
