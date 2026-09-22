import Foundation
import MLX
import PpCore

/// Fully local in-process decision provider running Laya 421M on Apple Silicon via MLX Swift.
///
/// Every question is expressed with an explicit, ordered option list. Option order is
/// what a decision head's index means, so the option list — never a dictionary — is
/// the source of truth for mapping a prediction back onto a candidate.
///
/// Yes/no questions are asked of the model's own `noul` head rather than inferred from
/// a choice confidence, with the two options always emitted `false` then `true` so the
/// probability of "yes" is `probabilities[1]`, matching the reference implementation.
public final class LayaDecisionProvider: DecisionProvider, @unchecked Sendable {
    public let model: LayaModel
    public let tokenizer: BPETokenizer
    public var requiresAPIKey: Bool { false }

    /// Fixed instruction used for the "is there more to do" question after an action.
    public static let moreStepsInstructions =
        "After the chosen action is performed, will the command still require more steps before it is fully finished?"
    public static let moreStepsFalse = "The chosen action completes everything the command asked for."
    public static let moreStepsTrue = "The command asks for more actions after this one."

    public init(model: LayaModel, tokenizer: BPETokenizer) {
        self.model = model
        self.tokenizer = tokenizer
    }

    public static func load(from directoryUrl: URL) throws -> LayaDecisionProvider {
        let model = try LayaModel.load(from: directoryUrl)
        let tokenizer = try BPETokenizer.load(from: directoryUrl)
        return LayaDecisionProvider(model: model, tokenizer: tokenizer)
    }

    // MARK: Heads

    /// One ordered choice question. Returns the chosen index and calibrated probabilities.
    public func choose(state: String, instructions: String, options: [String]) -> (index: Int, probabilities: [Float], confidence: Double) {
        guard !options.isEmpty else { return (0, [], 0) }
        let built = SequenceBuilder.buildSequence(
            tokenizer: tokenizer, state: state, questionType: "choice",
            instructions: instructions, options: options, maxLen: 512)
        let prediction = model.evaluate(inputIds: built.inputIds, markerPositions: built.markers, questionType: "choice")
        let index = min(max(prediction.topChoiceIndex, 0), options.count - 1)
        return (index, prediction.probabilities, Double(prediction.confidence))
    }

    /// One yes/no question, answered by the `noul` head.
    public func yesNo(state: String, instructions: String, trueCriterion: String, falseCriterion: String) -> (probability: Double, confidence: Double) {
        let options = ["false: \(falseCriterion)", "true: \(trueCriterion)"]
        let built = SequenceBuilder.buildSequence(
            tokenizer: tokenizer, state: state, questionType: "noul",
            instructions: instructions, options: options, maxLen: 512)
        let prediction = model.evaluate(inputIds: built.inputIds, markerPositions: built.markers, questionType: "noul")
        let probability = prediction.probabilities.count > 1 ? Double(prediction.probabilities[1]) : 0.0
        return (probability, Double(prediction.confidence))
    }

    // MARK: DecisionProvider

    public func decide(context: CommandContext, candidates: [Candidate], apiKey: String?) async throws -> Decision {
        guard !candidates.isEmpty else { return Decision(answers: [:]) }

        let state = "Application: \(context.application), Window: \(context.window), Command: \(context.command)"
        let options = candidates.map { "\($0.label): \($0.detail)" }
        let picked = choose(
            state: state,
            instructions: "Choose the one supplied desktop action that is the next step toward fulfilling the command.",
            options: options)

        let chosen = candidates[picked.index]
        var probabilities: [String: Double] = [:]
        for (index, probability) in picked.probabilities.enumerated() where index < candidates.count {
            probabilities[candidates[index].id] = Double(probability)
        }
        let actionAnswer = Decision.Answer(
            type: "choice", choice: chosen.id, confidence: picked.confidence,
            probabilities: probabilities, noul: nil)

        let more = yesNo(
            state: state,
            instructions: Self.moreStepsInstructions,
            trueCriterion: Self.moreStepsTrue,
            falseCriterion: Self.moreStepsFalse)
        let moreAnswer = Decision.Answer(
            type: "noul", choice: nil, confidence: more.confidence, probabilities: nil, noul: more.probability)

        return Decision(answers: ["action": actionAnswer, "more": moreAnswer])
    }

    public func cycle(state: JevClient.CycleState, operations: [String: String], heads: [String: [String: String]], apiKey: String?) async throws -> Decision {
        // Sorted keys, because a dictionary's order is not a contract and the chosen
        // index is mapped back onto this list.
        let keys = operations.keys.sorted()
        guard !keys.isEmpty else { return Decision(answers: [:]) }

        let stateStr = "Goal: \(state.goal), App: \(state.application), Window: \(state.window)"
        let options = keys.map { key in
            let detail = operations[key] ?? ""
            return detail.isEmpty ? key : "\(key): \(detail)"
        }

        let picked = choose(
            state: stateStr,
            instructions: "Select the next atomic operation to perform on the desktop interface.",
            options: options)
        let chosenOp = keys[picked.index]

        var probabilities: [String: Double] = [:]
        for (index, probability) in picked.probabilities.enumerated() where index < keys.count {
            probabilities[keys[index]] = Double(probability)
        }
        let operationAnswer = Decision.Answer(
            type: "choice", choice: chosenOp, confidence: picked.confidence,
            probabilities: probabilities, noul: nil)

        // A dictionary of heads can carry extra yes/no questions; answer each on the
        // noul head so the app is not guessing from a choice confidence.
        var answers: [String: Decision.Answer] = ["operation": operationAnswer]
        let finish = yesNo(
            state: stateStr,
            instructions: "After operation '\(chosenOp)' is performed, will the goal '\(state.goal)' be completely finished with nothing more left to do?",
            trueCriterion: "This single operation fulfils every part of what was asked.",
            falseCriterion: "The goal asks for more actions after this one, or the operation is not the last step.")
        answers["finishes"] = Decision.Answer(
            type: "noul", choice: nil, confidence: finish.confidence, probabilities: nil, noul: finish.probability)

        for (head, criteria) in heads.sorted(by: { $0.key < $1.key }) {
            let question = yesNo(
                state: stateStr,
                instructions: "Question '\(head)' about the goal '\(state.goal)' after operation '\(chosenOp)'.",
                trueCriterion: criteria["true"] ?? "Yes.",
                falseCriterion: criteria["false"] ?? "No.")
            answers[head] = Decision.Answer(
                type: "noul", choice: nil, confidence: question.confidence, probabilities: nil, noul: question.probability)
        }

        return Decision(answers: answers)
    }

    public func ground(context: JevClient.GroundingContext, candidates: [Candidate], apiKey: String?) async throws -> Decision {
        guard !candidates.isEmpty else {
            let target = Decision.Answer(type: "choice", choice: "none", confidence: 1.0, probabilities: ["none": 1.0], noul: nil)
            return Decision(answers: ["target": target])
        }

        let stateStr = "Step: \(context.step.summary), Goal: \(context.goal), App: \(context.application), Window: \(context.window)"
        // "none" is a real option, in a known position, not a post-hoc correction.
        let options = candidates.map { "\($0.label): \($0.detail)" } + ["none: no listed item matches the step"]
        let picked = choose(
            state: stateStr,
            instructions: "Which listed item is the one that the step describes? Match by label, purpose and position. The last option means none of them.",
            options: options)

        let chosenId = picked.index < candidates.count ? candidates[picked.index].id : "none"
        var probabilities: [String: Double] = [:]
        for (index, probability) in picked.probabilities.enumerated() {
            let key = index < candidates.count ? candidates[index].id : "none"
            probabilities[key] = Double(probability)
        }
        let targetAnswer = Decision.Answer(
            type: "choice", choice: chosenId, confidence: picked.confidence,
            probabilities: probabilities, noul: nil)

        let alreadyDone = yesNo(
            state: stateStr,
            instructions: "Does the current screen already show that the step '\(context.step.summary)' has been completed, so performing it again would be redundant?",
            trueCriterion: "The step's effect is already visible.",
            falseCriterion: "The step still needs to be performed.")
        let alreadyDoneAnswer = Decision.Answer(
            type: "noul", choice: nil, confidence: alreadyDone.confidence, probabilities: nil, noul: alreadyDone.probability)

        return Decision(answers: ["target": targetAnswer, "already_done": alreadyDoneAnswer])
    }

    public func warmUp() {
        _ = model.evaluate(
            inputIds: [tokenizer.clsTokenId, tokenizer.maskTokenId, tokenizer.sepTokenId],
            markerPositions: [1],
            questionType: "choice"
        )
    }
}
