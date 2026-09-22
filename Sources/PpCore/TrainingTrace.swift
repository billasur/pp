import Foundation

/// One usable training example, derived from a real interaction.
///
/// Only the decision *question* is recorded: the option list, which one was chosen, and
/// whether it worked. The screen it came from is reduced to a fingerprint, so the page
/// or message body never enters the training set.
public struct TrainingExample: Codable, Equatable, Sendable {
    public static let currentSchema = 1

    public let schemaVersion: Int
    public let id: UUID
    public let createdAt: Date
    public let questionType: String
    public let instructions: String
    public let options: [String]
    public let selectedIndex: Int
    public let succeeded: Bool
    public let modelVersion: String
    public let structureFingerprint: String
    /// "interactive" or "replay". Provenance is recorded so a future shared model could
    /// deliberately exclude one or the other.
    public let provenance: String

    public init(schemaVersion: Int = TrainingExample.currentSchema, id: UUID = UUID(), createdAt: Date,
                questionType: String, instructions: String, options: [String], selectedIndex: Int,
                succeeded: Bool, modelVersion: String, structureFingerprint: String, provenance: String) {
        self.schemaVersion = schemaVersion; self.id = id; self.createdAt = createdAt
        self.questionType = questionType; self.instructions = instructions; self.options = options
        self.selectedIndex = selectedIndex; self.succeeded = succeeded; self.modelVersion = modelVersion
        self.structureFingerprint = structureFingerprint; self.provenance = provenance
    }
}

public enum TraceRejection: LocalizedError, Equatable {
    case notSuccessful
    case selectedIndexOutOfRange
    case sensitiveOption(String)
    case staleSchema(Int)
    case emptyOptions

    public var errorDescription: String? {
        switch self {
        case .notSuccessful: return "Only successful interactions become training examples."
        case .selectedIndexOutOfRange: return "The chosen option is not in the option list."
        case .sensitiveOption(let option): return "An option looks like a credential or one-time code ('\(option)')."
        case .staleSchema(let version): return "That example uses training schema \(version), which this build does not understand."
        case .emptyOptions: return "An example with no options teaches nothing."
        }
    }
}

/// Builds and validates training examples. Every example passes through
/// `PrivacyFilter`-equivalent rules before it can exist.
public enum TrainingTraceBuilder {

    /// Returns nil rather than a questionable example: a rejected trace teaches nothing
    /// and a bad one teaches the wrong thing.
    public static func example(
        question: LayaQuestion,
        selectedIndex: Int,
        succeeded: Bool,
        modelVersion: String,
        structureFingerprint: String,
        createdAt: Date = Date(),
        provenance: String = "interactive"
    ) -> TrainingExample? {
        guard succeeded else { return nil }
        guard !question.options.isEmpty else { return nil }
        guard question.options.indices.contains(selectedIndex) else { return nil }
        guard !question.options.contains(where: { PrivacyFilter.looksLikeSecret($0) || PrivacyFilter.isSensitiveField($0) }) else {
            return nil
        }
        return TrainingExample(
            createdAt: createdAt,
            questionType: question.type,
            instructions: question.instructions,
            options: question.options,
            selectedIndex: selectedIndex,
            succeeded: true,
            modelVersion: modelVersion,
            structureFingerprint: structureFingerprint,
            provenance: provenance)
    }

    /// The same rules, applied to an example that already exists (import, resume).
    public static func validate(_ example: TrainingExample, supportedSchema: Int = TrainingExample.currentSchema) throws {
        guard example.schemaVersion <= supportedSchema else { throw TraceRejection.staleSchema(example.schemaVersion) }
        guard example.succeeded else { throw TraceRejection.notSuccessful }
        guard !example.options.isEmpty else { throw TraceRejection.emptyOptions }
        guard example.options.indices.contains(example.selectedIndex) else { throw TraceRejection.selectedIndexOutOfRange }
        if let offending = example.options.first(where: { PrivacyFilter.looksLikeSecret($0) || PrivacyFilter.isSensitiveField($0) }) {
            throw TraceRejection.sensitiveOption(offending)
        }
    }

    /// Whether a whole corpus is usable. One bad example fails the batch rather than
    /// being silently dropped.
    public static func validateAll(_ examples: [TrainingExample], supportedSchema: Int = TrainingExample.currentSchema) throws {
        for example in examples { try validate(example, supportedSchema: supportedSchema) }
    }
}

/// Somewhere training examples can be kept. Deliberately separate from `EventLog`, so a
/// profile's training set can be inspected and deleted on its own.
public final class TrainingCorpus: @unchecked Sendable {
    private let lock = NSLock()
    private var examples: [TrainingExample] = []

    public init(examples: [TrainingExample] = []) {
        self.examples = examples
    }

    public var all: [TrainingExample] {
        lock.lock(); defer { lock.unlock() }
        return examples
    }

    public var count: Int { all.count }

    /// Adds only if the example is valid; returns whether it was kept.
    @discardableResult
    public func add(_ example: TrainingExample) -> Bool {
        guard (try? TrainingTraceBuilder.validate(example)) != nil else { return false }
        lock.lock(); defer { lock.unlock() }
        examples.append(example)
        return true
    }

    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        examples.removeAll()
    }

    public func export() throws -> Data {
        try PpJSON.encoder(pretty: true).encode(all)
    }

    public func importCorpus(_ data: Data) throws {
        let decoded = try PpJSON.decoder().decode([TrainingExample].self, from: data)
        try TrainingTraceBuilder.validateAll(decoded)
        lock.lock(); defer { lock.unlock() }
        examples = decoded
    }
}
