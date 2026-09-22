import CryptoKit
import Foundation

/// One successful (or failed) command, with the steps that were run for it.
public struct CommandTrace: Codable, Equatable, Sendable {
    public let clause: String
    public let steps: [PlanStep]
    public let succeeded: Bool
    public let app: String

    public init(clause: String, steps: [PlanStep], succeeded: Bool, app: String) {
        self.clause = clause; self.steps = steps; self.succeeded = succeeded; self.app = app
    }
}

/// A repeated command, parameterised and ready to replay without the decision model.
public struct Macro: Codable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var triggerPattern: String
    public var triggerTokens: [String]
    public var app: String?
    public var preconditions: [String]
    public var steps: [PlanStep]
    public var variables: [String]
    public var verification: String
    public var successCount: Int
    public var lastUsedAt: Date
    public var enabled: Bool

    public init(id: String, name: String, triggerPattern: String, triggerTokens: [String], app: String?,
                preconditions: [String], steps: [PlanStep], variables: [String], verification: String,
                successCount: Int, lastUsedAt: Date, enabled: Bool = true) {
        self.id = id; self.name = name; self.triggerPattern = triggerPattern; self.triggerTokens = triggerTokens
        self.app = app; self.preconditions = preconditions; self.steps = steps; self.variables = variables
        self.verification = verification; self.successCount = successCount; self.lastUsedAt = lastUsedAt
        self.enabled = enabled
    }

    /// How well a spoken clause matches this macro, 0...1.
    public func match(_ clause: String) -> Double {
        guard !triggerTokens.isEmpty else { return 0 }
        let spoken = Set(MacroMiner.significantTokens(clause))
        guard !spoken.isEmpty else { return 0 }
        let overlap = Double(triggerTokens.filter { spoken.contains($0) }.count)
        return overlap / Double(triggerTokens.count)
    }
}

/// Turns repeated successes into macros.
///
/// A macro is only mined from commands that *succeeded*, at least `minimumSupport`
/// times, with an identical step shape. Options are never invented: the steps come
/// from what actually ran.
public enum MacroMiner {
    public static let stopWords: Set<String> = [
        "the", "a", "an", "and", "then", "to", "for", "of", "in", "on", "at", "it",
        "this", "that", "my", "me", "please", "also", "with", "into", "is", "are"
    ]

    public static func significantTokens(_ clause: String) -> [String] {
        clause.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 2 && !stopWords.contains($0) }
    }

    /// Identical shape, ignoring the parts that are data rather than intent.
    public static func signature(for steps: [PlanStep]) -> String {
        let shape = steps.map { step -> String in
            switch step.kind {
            case .typeText: return "type_text:{text}"
            case .openURL: return "open_url:{url}"
            case .openFolder: return "open_folder:{folder}"
            case .openApp, .quitApp, .click, .menu, .focusInput: return "\(step.kind.rawValue):\((step.target ?? "").lowercased())"
            case .pressKey: return "press_key:\((step.target ?? "").lowercased())"
            case .scroll, .skip: return "\(step.kind.rawValue):\((step.target ?? "").lowercased()):\(step.amount ?? 0)"
            }
        }.joined(separator: ">")
        return SHA256.hash(data: Data(shape.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    /// The slots that vary between invocations, named for the UI.
    public static func variables(for steps: [PlanStep]) -> [String] {
        var names: [String] = []
        for step in steps {
            switch step.kind {
            case .typeText: names.append("text")
            case .openURL: names.append("url")
            case .openFolder: names.append("folder")
            default: break
            }
        }
        return names
    }

    public static func mine(traces: [CommandTrace], minimumSupport: Int = 3, now: Date = Date()) -> [Macro] {
        let succeeded = traces.filter(\.succeeded)
        let grouped = Dictionary(grouping: succeeded) { signature(for: $0.steps) }

        return grouped.compactMap { signature, group -> Macro? in
            guard group.count >= minimumSupport else { return nil }
            guard let representative = group.min(by: { $0.clause.count < $1.clause.count }) else { return nil }

            let apps = Set(group.map(\.app))
            let preconditions = apps.count == 1 ? ["frontmost app is \(representative.app)"] : []
            let tokens = significantTokens(representative.clause)

            return Macro(
                id: signature,
                name: representative.clause,
                triggerPattern: representative.clause,
                triggerTokens: tokens,
                app: apps.count == 1 ? representative.app : nil,
                preconditions: preconditions,
                steps: representative.steps,
                variables: variables(for: representative.steps),
                verification: representative.steps.last.map { ExpectedEffect.expected(for: $0).kind.rawValue } ?? "none",
                successCount: group.count,
                lastUsedAt: now
            )
        }
        .sorted { $0.successCount > $1.successCount }
    }
}

/// Macros retrieved before the model runs, so a repeated command costs almost nothing.
public final class MacroLibrary: @unchecked Sendable {
    private let lock = NSLock()
    private var macros: [Macro]

    public init(macros: [Macro] = []) {
        self.macros = macros
    }

    public func all() -> [Macro] {
        lock.lock(); defer { lock.unlock() }
        return macros
    }

    public func insert(_ macro: Macro) {
        lock.lock(); defer { lock.unlock() }
        if let index = macros.firstIndex(where: { $0.id == macro.id }) {
            macros[index] = macro
        } else {
            macros.append(macro)
        }
    }

    public func remove(id: String) {
        lock.lock(); defer { lock.unlock() }
        macros.removeAll { $0.id == id }
    }

    public func replaceAll(_ newMacros: [Macro]) {
        lock.lock(); defer { lock.unlock() }
        macros = newMacros
    }

    /// Best matching enabled macro, or nil. Bounded work: one token pass over a list
    /// that only ever holds commands this user has actually repeated.
    public func bestMatch(for clause: String, app: String?, threshold: Double = 0.6) -> Macro? {
        let snapshot = all().filter(\.enabled)
        guard !snapshot.isEmpty else { return nil }
        var best: (Macro, Double)?
        for macro in snapshot {
            if let required = macro.app, let app, required.caseInsensitiveCompare(app) != .orderedSame {
                continue
            }
            let score = macro.match(clause)
            if score >= threshold, best == nil || score > best!.1 {
                best = (macro, score)
            }
        }
        return best?.0
    }
}
