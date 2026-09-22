import Foundation
import PpCore
import MLX

/// Fully local in-process decision provider running Laya 421M on Apple Silicon via MLX Swift.
public final class LayaDecisionProvider: DecisionProvider, @unchecked Sendable {
    public let model: LayaModel
    public let tokenizer: BPETokenizer
    public var requiresAPIKey: Bool { false }

    public init(model: LayaModel, tokenizer: BPETokenizer) {
        self.model = model
        self.tokenizer = tokenizer
    }

    public static func load(from directoryUrl: URL) throws -> LayaDecisionProvider {
        let model = try LayaModel.load(from: directoryUrl)
        let tokenizer = try BPETokenizer.load(from: directoryUrl)
        return LayaDecisionProvider(model: model, tokenizer: tokenizer)
    }

    public func decide(context: CommandContext, candidates: [Candidate], apiKey: String?) async throws -> Decision {
        guard !candidates.isEmpty else {
            return Decision(answers: [:])
        }

        // 1. Serialize context state
        let stateStr = "Application: \(context.application), Window: \(context.window), Command: \(context.command)"

        // 2. Build criteria dictionary
        var criteria: [String: String] = [:]
        for c in candidates {
            criteria[c.id] = "\(c.label): \(c.detail)"
        }

        let question: [String: Any] = [
            "t": "choice",
            "ins": "Choose the one supplied desktop action that is the next step toward fulfilling the command.",
            "crit": criteria
        ]

        let built = SequenceBuilder.buildSequence(
            tokenizer: tokenizer,
            state: stateStr,
            question: question,
            maxLen: 512
        )

        let pred = model.evaluate(
            inputIds: built.inputIds,
            markerPositions: built.markers,
            questionType: "choice"
        )

        let safeIndex = min(pred.topChoiceIndex, candidates.count - 1)
        let chosenCandidateId = candidates[safeIndex].id

        var probsDict: [String: Double] = [:]
        for (i, p) in pred.probabilities.enumerated() {
            if i < candidates.count {
                probsDict[candidates[i].id] = Double(p)
            }
        }

        let actionAnswer = Decision.Answer(
            type: "choice",
            choice: chosenCandidateId,
            confidence: Double(pred.confidence),
            probabilities: probsDict,
            noul: nil
        )

        let moreAnswer = Decision.Answer(
            type: "noul",
            choice: nil,
            confidence: Double(pred.confidence),
            probabilities: nil,
            noul: Double(pred.confidence > 0.8 ? 0.0 : 0.5)
        )

        return Decision(answers: ["action": actionAnswer, "more": moreAnswer])
    }

    public func cycle(state: JevClient.CycleState, operations: [String: String], heads: [String: [String: String]], apiKey: String?) async throws -> Decision {
        let stateStr = "Goal: \(state.goal), App: \(state.application), Window: \(state.window)"
        let question: [String: Any] = [
            "t": "choice",
            "ins": "Select the next atomic operation to perform on the desktop interface.",
            "crit": operations
        ]

        let built = SequenceBuilder.buildSequence(
            tokenizer: tokenizer,
            state: stateStr,
            question: question,
            maxLen: 512
        )

        let pred = model.evaluate(
            inputIds: built.inputIds,
            markerPositions: built.markers,
            questionType: "choice"
        )

        let opKeys = Array(operations.keys)
        let safeIndex = min(pred.topChoiceIndex, opKeys.count - 1)
        let chosenOp = opKeys[safeIndex]

        let opAnswer = Decision.Answer(
            type: "choice",
            choice: chosenOp,
            confidence: Double(pred.confidence),
            probabilities: [chosenOp: Double(pred.probabilities[safeIndex])],
            noul: nil
        )

        // Evaluate noul head for finishes
        let finishQuestion: [String: Any] = [
            "t": "noul",
            "ins": "After performing operation '\(chosenOp)', will the goal '\(state.goal)' be completely finished with nothing more to do?",
            "crit": [
                "false": "The goal asks for more actions after this one.",
                "true": "This single operation fulfills every part of what was asked."
            ]
        ]
        let finishBuilt = SequenceBuilder.buildSequence(
            tokenizer: tokenizer,
            state: stateStr,
            question: finishQuestion,
            maxLen: 512
        )
        let finishPred = model.evaluate(
            inputIds: finishBuilt.inputIds,
            markerPositions: finishBuilt.markers,
            questionType: "noul"
        )
        let finishProb = finishPred.probabilities.count > 1 ? Double(finishPred.probabilities[1]) : (chosenOp == "DONE" ? 1.0 : 0.0)

        let finishAnswer = Decision.Answer(
            type: "noul",
            choice: nil,
            confidence: Double(finishPred.confidence),
            probabilities: nil,
            noul: finishProb
        )

        return Decision(answers: ["operation": opAnswer, "finishes": finishAnswer])
    }

    public func ground(context: JevClient.GroundingContext, candidates: [Candidate], apiKey: String?) async throws -> Decision {
        guard !candidates.isEmpty else {
            let targetAnswer = Decision.Answer(type: "choice", choice: "none", confidence: 1.0, probabilities: ["none": 1.0], noul: nil)
            return Decision(answers: ["target": targetAnswer])
        }

        let stateStr = "Step: \(context.step.summary), Goal: \(context.goal), App: \(context.application), Window: \(context.window)"
        var criteria: [String: String] = [:]
        for c in candidates {
            criteria[c.id] = "\(c.label): \(c.detail)"
        }

        let question: [String: Any] = [
            "t": "choice",
            "ins": "Identify the target on-screen UI element that corresponds to the requested step.",
            "crit": criteria
        ]

        let built = SequenceBuilder.buildSequence(
            tokenizer: tokenizer,
            state: stateStr,
            question: question,
            maxLen: 512
        )

        let pred = model.evaluate(
            inputIds: built.inputIds,
            markerPositions: built.markers,
            questionType: "choice"
        )

        let safeIndex = min(pred.topChoiceIndex, candidates.count - 1)
        let chosenCandidateId = candidates[safeIndex].id

        var probsDict: [String: Double] = [:]
        for (i, p) in pred.probabilities.enumerated() {
            if i < candidates.count {
                probsDict[candidates[i].id] = Double(p)
            }
        }

        let targetAnswer = Decision.Answer(
            type: "choice",
            choice: chosenCandidateId,
            confidence: Double(pred.confidence),
            probabilities: probsDict,
            noul: nil
        )

        // Evaluate noul head for already_done
        let alreadyDoneQuestion: [String: Any] = [
            "t": "noul",
            "ins": "Looking at the current application state, has the step '\(context.step.summary)' already been completed?",
            "crit": [
                "false": "The step still needs to be performed.",
                "true": "The step is already completed."
            ]
        ]
        let alreadyDoneBuilt = SequenceBuilder.buildSequence(
            tokenizer: tokenizer,
            state: stateStr,
            question: alreadyDoneQuestion,
            maxLen: 512
        )
        let alreadyDonePred = model.evaluate(
            inputIds: alreadyDoneBuilt.inputIds,
            markerPositions: alreadyDoneBuilt.markers,
            questionType: "noul"
        )
        let alreadyDoneProb = alreadyDonePred.probabilities.count > 1 ? Double(alreadyDonePred.probabilities[1]) : 0.0

        let alreadyDoneAnswer = Decision.Answer(
            type: "noul",
            choice: nil,
            confidence: Double(alreadyDonePred.confidence),
            probabilities: nil,
            noul: alreadyDoneProb
        )

        return Decision(answers: ["target": targetAnswer, "already_done": alreadyDoneAnswer])
    }

    public func warmUp() {
        _ = model.evaluate(
            inputIds: [tokenizer.clsTokenId, tokenizer.sepTokenId, tokenizer.maskTokenId],
            markerPositions: [2],
            questionType: "choice"
        )
    }
}
