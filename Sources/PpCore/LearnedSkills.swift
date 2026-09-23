import Foundation

public struct LearnedSkill: Codable, Equatable, Sendable {
    public let goal: String
    public let app: String
    public let script: String
    public let learnedAt: Date

    public init(goal: String, app: String, script: String, learnedAt: Date = Date()) {
        self.goal = goal
        self.app = app
        self.script = script
        self.learnedAt = learnedAt
    }
}

public actor LearnedSkills {
    public static let shared = LearnedSkills()
    private let fileURL: URL
    private var cache: [String: LearnedSkill] = [:]

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let ppDir = appSupport.appendingPathComponent("pp", isDirectory: true)
            try? FileManager.default.createDirectory(at: ppDir, withIntermediateDirectories: true)
            self.fileURL = ppDir.appendingPathComponent("learned.json")
        }
    }

    public func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let items = try? JSONDecoder().decode([String: LearnedSkill].self, from: data) else {
            cache = [:]
            return
        }
        cache = items
    }

    public func save() {
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    public func get(goal: String, app: String) -> LearnedSkill? {
        let key = "\(app.lowercased())::\(goal.lowercased())"
        return cache[key]
    }

    public func store(goal: String, app: String, script: String) {
        let key = "\(app.lowercased())::\(goal.lowercased())"
        cache[key] = LearnedSkill(goal: goal, app: app, script: script)
        save()
    }

    public func clearAll() {
        cache.removeAll()
        save()
    }
}
