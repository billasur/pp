import Foundation

/// Safe stub provider returning no-op decisions or empty answers with zero network calls.
public final class StubProvider: DecisionProvider, @unchecked Sendable {
    public enum Mode: Sendable {
        case safeNoOp
        case emptyAnswers
        case custom(Decision)
    }

    public var mode: Mode
    public var requiresAPIKey: Bool { false }

    public init(mode: Mode = .safeNoOp) {
        self.mode = mode
    }

    public func decide(context: CommandContext, candidates: [Candidate], apiKey: String?) async throws -> Decision {
        switch mode {
        case .safeNoOp:
            let actionAnswer = Decision.Answer(type: "choice", choice: "done", confidence: 1.0, probabilities: ["done": 1.0], noul: 0.0)
            let moreAnswer = Decision.Answer(type: "noul", choice: nil, confidence: 1.0, probabilities: nil, noul: 0.0)
            return Decision(answers: ["action": actionAnswer, "more": moreAnswer])
        case .emptyAnswers:
            return Decision(answers: [:])
        case .custom(let decision):
            return decision
        }
    }

    public func cycle(state: JevClient.CycleState, operations: [String: String], heads: [String: [String: String]], apiKey: String?) async throws -> Decision {
        switch mode {
        case .safeNoOp:
            let opAnswer = Decision.Answer(type: "choice", choice: "DONE", confidence: 1.0, probabilities: ["DONE": 1.0], noul: nil)
            let finishAnswer = Decision.Answer(type: "noul", choice: nil, confidence: 1.0, probabilities: nil, noul: 1.0)
            return Decision(answers: ["operation": opAnswer, "finishes": finishAnswer])
        case .emptyAnswers:
            return Decision(answers: [:])
        case .custom(let decision):
            return decision
        }
    }

    public func ground(context: JevClient.GroundingContext, candidates: [Candidate], apiKey: String?) async throws -> Decision {
        switch mode {
        case .safeNoOp:
            let targetAnswer = Decision.Answer(type: "choice", choice: "none", confidence: 1.0, probabilities: ["none": 1.0], noul: nil)
            let alreadyDoneAnswer = Decision.Answer(type: "noul", choice: nil, confidence: 1.0, probabilities: nil, noul: 1.0)
            return Decision(answers: ["target": targetAnswer, "already_done": alreadyDoneAnswer])
        case .emptyAnswers:
            return Decision(answers: [:])
        case .custom(let decision):
            return decision
        }
    }

    public func warmUp() {
        // Safe no-op
    }
}
