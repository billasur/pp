import Foundation

/// What pp has learned about this person's setup. Priors only ever reorder candidates.
public struct RankingFeatures: Codable, Equatable, Sendable {
    /// "mail" -> "Spark", "browser" -> "Zen".
    public var appAliases: [String: String]
    /// Control labels that worked, keyed by "app|label".
    public var successfulTargets: [String: Int]
    /// How often a name was the recipient of something.
    public var frequentContacts: [String: Int]
    /// Menu paths that worked, keyed by "app|item".
    public var menuPaths: [String: [String]]
    public var preferredBrowser: String?

    public init(appAliases: [String: String] = [:], successfulTargets: [String: Int] = [:],
                frequentContacts: [String: Int] = [:], menuPaths: [String: [String]] = [:],
                preferredBrowser: String? = nil) {
        self.appAliases = appAliases; self.successfulTargets = successfulTargets
        self.frequentContacts = frequentContacts; self.menuPaths = menuPaths
        self.preferredBrowser = preferredBrowser
    }

    /// Learns from stored history. Only successful events are in the log at all.
    public static func learn(from events: [InteractionEvent], minimumUses: Int = 3) -> RankingFeatures {
        var features = RankingFeatures()
        for event in events {
            guard let label = event.targetLabel else { continue }
            let key = "\(event.app)|\(label.lowercased())"
            features.successfulTargets[key, default: 0] += 1
            if event.actionKind == "menu" {
                features.menuPaths["\(event.app)|\(label.lowercased())", default: []].append(label)
            }
        }
        features.successfulTargets = features.successfulTargets.filter { $0.value >= minimumUses }
        return features
    }

    /// Ranking boosts for the labels on screen right now.
    public func priorBoost(app: String?, labels: [String], minimumUses: Int = 3) -> [String: Double] {
        guard let app else { return [:] }
        var boosts: [String: Double] = [:]
        for label in labels {
            let key = "\(app)|\(label.lowercased())"
            if let uses = successfulTargets[key], uses >= minimumUses {
                boosts[label.lowercased()] = min(2.0, 0.2 * Double(uses))
            }
        }
        return boosts
    }
}

/// Ties the learned features to the shortlister.
///
/// The hard rule: this only produces an ordering. It cannot mark anything safe, and it
/// is never consulted by the safety critic.
public final class RankingModel: @unchecked Sendable {
    private let lock = NSLock()
    private var current: RankingFeatures
    public let minimumUses: Int

    public init(features: RankingFeatures = RankingFeatures(), minimumUses: Int = 3) {
        self.current = features
        self.minimumUses = minimumUses
    }

    public var features: RankingFeatures {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    public func replaceFeatures(_ features: RankingFeatures) {
        lock.lock(); defer { lock.unlock() }
        current = features
    }

    public func observe(_ event: InteractionEvent) {
        guard event.succeeded, let label = event.targetLabel else { return }
        lock.lock(); defer { lock.unlock() }
        current.successfulTargets["\(event.app)|\(label.lowercased())", default: 0] += 1
    }

    public func rank(_ candidates: [UICandidate], command: String, app: String?,
                     limit: Int = Shortlister.defaultLimit) -> [Candidate] {
        let features = self.features
        let boost = features.priorBoost(app: app, labels: candidates.map(\.label), minimumUses: minimumUses)
        return Shortlister.rank(candidates, command: command,
                                options: Shortlister.Options(limit: limit, priorBoost: boost))
    }
}
