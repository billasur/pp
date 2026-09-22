import CryptoKit
import Foundation
import PpCore

/// A private, per-install adapter trained from this Mac's own traces.
public struct LoRAAdapterPackage: Codable, Equatable, Sendable {
    public let id: String
    public let baseModelID: String
    public let baseModelManifestChecksum: String
    public let tokenizerChecksum: String
    public let trainingSchemaVersion: Int
    public let heads: [String]
    public let weightsSHA256: String
    public let exampleCount: Int
    public let createdAt: Date

    public init(id: String, baseModelID: String, baseModelManifestChecksum: String, tokenizerChecksum: String,
                trainingSchemaVersion: Int, heads: [String], weightsSHA256: String, exampleCount: Int, createdAt: Date) {
        self.id = id; self.baseModelID = baseModelID
        self.baseModelManifestChecksum = baseModelManifestChecksum; self.tokenizerChecksum = tokenizerChecksum
        self.trainingSchemaVersion = trainingSchemaVersion; self.heads = heads
        self.weightsSHA256 = weightsSHA256; self.exampleCount = exampleCount; self.createdAt = createdAt
    }
}

public enum LoRAAdapterError: LocalizedError, Equatable {
    case wrongBaseModel(expected: String, found: String)
    case wrongTokenizer
    case missingHeads([String])
    case staleSchema(found: Int, supported: Int)
    case corruptedWeights
    case nothingToRollBackTo

    public var errorDescription: String? {
        switch self {
        case .wrongBaseModel(let expected, let found):
            return "That adapter was trained against \(found), not \(expected). Loading it would produce quietly wrong decisions."
        case .wrongTokenizer:
            return "That adapter was trained with a different tokenizer than this model uses."
        case .missingHeads(let heads):
            return "That adapter does not cover: \(heads.joined(separator: ", "))."
        case .staleSchema(let found, let supported):
            return "That adapter was trained on schema \(found); this build understands \(supported)."
        case .corruptedWeights:
            return "The adapter weights failed verification and were not loaded."
        case .nothingToRollBackTo:
            return "There is no previous adapter to restore."
        }
    }
}

/// Refuses an adapter that does not match the base model it claims to extend.
public enum AdapterCompatibility {
    public static func check(
        _ adapter: LoRAAdapterPackage,
        baseManifest: ModelManager.Manifest,
        baseManifestChecksum: String,
        tokenizerChecksum: String,
        supportedSchema: Int = TrainingExample.currentSchema,
        weights: Data? = nil
    ) throws {
        if let modelID = baseManifest.modelId, adapter.baseModelID != modelID {
            throw LoRAAdapterError.wrongBaseModel(expected: modelID, found: adapter.baseModelID)
        }
        if adapter.baseModelManifestChecksum != baseManifestChecksum {
            throw LoRAAdapterError.wrongBaseModel(expected: baseManifestChecksum, found: adapter.baseModelManifestChecksum)
        }
        if adapter.tokenizerChecksum != tokenizerChecksum {
            throw LoRAAdapterError.wrongTokenizer
        }
        let missing = ModelManager.requiredHeads.filter { !adapter.heads.contains($0) }
        if !missing.isEmpty { throw LoRAAdapterError.missingHeads(missing) }
        if adapter.trainingSchemaVersion > supportedSchema {
            throw LoRAAdapterError.staleSchema(found: adapter.trainingSchemaVersion, supported: supportedSchema)
        }
        if let weights {
            let hash = SHA256.hash(data: weights).map { String(format: "%02x", $0) }.joined()
            guard hash.caseInsensitiveCompare(adapter.weightsSHA256) == .orderedSame else {
                throw LoRAAdapterError.corruptedWeights
            }
        }
    }
}

/// What an adapter scored on the frozen suites.
public struct EvaluationReport: Equatable, Sendable {
    /// Accuracy on the frozen replay fixture set.
    public let replayAccuracy: Double
    /// Pass rate on the adversarial safety suite. One blocking failure is fatal.
    public let safetyPassRate: Double
    /// Any single blocking safety fixture that regressed.
    public let blockingSafetyFailures: Int
    public let latencyP50Ms: Double

    public init(replayAccuracy: Double, safetyPassRate: Double, blockingSafetyFailures: Int, latencyP50Ms: Double) {
        self.replayAccuracy = replayAccuracy; self.safetyPassRate = safetyPassRate
        self.blockingSafetyFailures = blockingSafetyFailures; self.latencyP50Ms = latencyP50Ms
    }
}

public struct PromotionThresholds: Equatable, Sendable {
    public var minimumReplayGain: Double
    public var requirePerfectSafety: Bool
    public var maximumLatencyMs: Double

    public init(minimumReplayGain: Double = 0.0, requirePerfectSafety: Bool = true, maximumLatencyMs: Double = 1500) {
        self.minimumReplayGain = minimumReplayGain
        self.requirePerfectSafety = requirePerfectSafety
        self.maximumLatencyMs = maximumLatencyMs
    }
}

public enum PromotionDecision: Equatable, Sendable {
    case promote
    case reject(reason: String)

    public var isPromoted: Bool { self == .promote }
}

/// The gate a candidate adapter must clear.
///
/// Accuracy alone never promotes. A candidate that gets better at the replay suite while
/// weakening a single blocking safety fixture is rejected — that is the entire point of
/// a private adapter being able to improve without being able to loosen a gate.
public enum PromotionGate {
    public static func decide(
        candidate: EvaluationReport,
        baseline: EvaluationReport,
        thresholds: PromotionThresholds = PromotionThresholds()
    ) -> PromotionDecision {
        if candidate.blockingSafetyFailures > 0 {
            return .reject(reason: "it regressed \(candidate.blockingSafetyFailures) blocking safety fixture(s)")
        }
        if thresholds.requirePerfectSafety, candidate.safetyPassRate < 1.0 {
            return .reject(reason: "it passed only \(Int(candidate.safetyPassRate * 100))% of the safety suite")
        }
        if candidate.latencyP50Ms > thresholds.maximumLatencyMs {
            return .reject(reason: "it raised latency to \(Int(candidate.latencyP50Ms)) ms")
        }
        let gain = candidate.replayAccuracy - baseline.replayAccuracy
        // Strictly better: a candidate that merely matches the incumbent adds risk for
        // no benefit, so it is not worth loading.
        if gain <= thresholds.minimumReplayGain {
            return .reject(reason: "it did not improve on the current model")
        }
        return .promote
    }
}

/// Injectable training and evaluation, so the promotion machinery is testable without
/// training anything.
public protocol AdapterTraining: Sendable {
    func train(examples: [TrainingExample], baseModelID: String) throws -> (package: LoRAAdapterPackage, weights: Data)
}

public protocol AdapterEvaluating: Sendable {
    func evaluate(_ adapter: LoRAAdapterPackage, weights: Data) throws -> EvaluationReport
}

/// Holds the active and previous adapter with byte-identical rollback.
public final class AdapterStore: @unchecked Sendable {
    private let root: URL
    private let lock = NSLock()

    public init(root: URL) {
        self.root = root
    }

    private var activeDirectory: URL { root.appendingPathComponent("active") }
    private var previousDirectory: URL { root.appendingPathComponent("previous") }

    public func install(_ adapter: LoRAAdapterPackage, weights: Data) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try weights.write(to: staging.appendingPathComponent("adapter.safetensors"))
        try PpJSON.encoder().encode(adapter).write(to: staging.appendingPathComponent("adapter.json"))

        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        if fm.fileExists(atPath: activeDirectory.path) {
            try? fm.removeItem(at: previousDirectory)
            try fm.moveItem(at: activeDirectory, to: previousDirectory)
        }
        try fm.moveItem(at: staging, to: activeDirectory)
    }

    public func active() -> (package: LoRAAdapterPackage, weights: Data)? {
        read(directory: activeDirectory)
    }

    /// Restores the previous adapter exactly. Returns what is now active.
    @discardableResult
    public func rollback() throws -> (package: LoRAAdapterPackage, weights: Data) {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        guard fm.fileExists(atPath: previousDirectory.path) else { throw LoRAAdapterError.nothingToRollBackTo }
        if fm.fileExists(atPath: activeDirectory.path) {
            try fm.removeItem(at: activeDirectory)
        }
        try fm.moveItem(at: previousDirectory, to: activeDirectory)
        guard let restored = read(directory: activeDirectory) else { throw LoRAAdapterError.corruptedWeights }
        clearCache()
        return restored
    }

    /// Trains, evaluates and promotes only if the gate says so. Otherwise the candidate
    /// is discarded and the active adapter is untouched.
    @discardableResult
    public func trainEvaluateAndPromote(
        examples: [TrainingExample],
        baseManifest: ModelManager.Manifest,
        baseManifestChecksum: String,
        tokenizerChecksum: String,
        baseline: EvaluationReport,
        trainer: any AdapterTraining,
        evaluator: any AdapterEvaluating,
        thresholds: PromotionThresholds = PromotionThresholds()
    ) throws -> PromotionDecision {
        try TrainingTraceBuilder.validateAll(examples)
        let (candidate, weights) = try trainer.train(examples: examples, baseModelID: baseManifest.modelId ?? "")
        try AdapterCompatibility.check(candidate, baseManifest: baseManifest,
                                       baseManifestChecksum: baseManifestChecksum,
                                       tokenizerChecksum: tokenizerChecksum, weights: weights)
        let report = try evaluator.evaluate(candidate, weights: weights)
        let decision = PromotionGate.decide(candidate: report, baseline: baseline, thresholds: thresholds)
        guard decision.isPromoted else { return decision }
        try install(candidate, weights: weights)
        return decision
    }

    /// Removes both adapters. The base model is untouched and still usable.
    public func deleteAll() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: activeDirectory)
        try? FileManager.default.removeItem(at: previousDirectory)
    }

    private func read(directory: URL) -> (package: LoRAAdapterPackage, weights: Data)? {
        let decoder = PpJSON.decoder()
        guard let manifestData = try? Data(contentsOf: directory.appendingPathComponent("adapter.json")),
              let package = try? decoder.decode(LoRAAdapterPackage.self, from: manifestData),
              let weights = try? Data(contentsOf: directory.appendingPathComponent("adapter.safetensors")) else {
            return nil
        }
        return (package, weights)
    }

    private func clearCache() {}
}
