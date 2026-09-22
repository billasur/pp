import Foundation
import MLX
import MLXNN

public struct LayaPrediction {
    public let qtype: String
    public let logits: [Float]
    public let probabilities: [Float]
    public let confidence: Float
    public let topChoiceIndex: Int
    public let expectedScore: Float?

    public init(
        qtype: String,
        logits: [Float],
        probabilities: [Float],
        confidence: Float,
        topChoiceIndex: Int,
        expectedScore: Float? = nil
    ) {
        self.qtype = qtype
        self.logits = logits
        self.probabilities = probabilities
        self.confidence = confidence
        self.topChoiceIndex = topChoiceIndex
        self.expectedScore = expectedScore
    }
}

public class LayaModel: Module {
    public let encoder: ModernBertModel
    public let head: LayaHead
    public let config: ModernBertConfig

    public init(config: ModernBertConfig) {
        self.config = config
        self.encoder = ModernBertModel(config)
        self.head = LayaHead(config: config)
    }

    public static func load(from directoryUrl: URL) throws -> LayaModel {
        let configUrl = directoryUrl.appendingPathComponent("config.json")
        let config = try ModernBertConfig.load(from: configUrl)
        let model = LayaModel(config: config)

        let weightsUrl = directoryUrl.appendingPathComponent("model.safetensors")
        let weights = try loadArrays(url: weightsUrl)

        // Update model parameters
        try model.update(parameters: weights)
        return model
    }

    public func update(parameters: [String: MLXArray]) throws {
        var remapped: [String: MLXArray] = [:]
        for (k, v) in parameters {
            if k.hasPrefix("embeddings.") || k.hasPrefix("layers.") || k.hasPrefix("final_norm.") {
                remapped["encoder." + k] = v
            } else if k.hasPrefix("head.layers.") {
                remapped[k] = v
            } else if k.hasPrefix("type_emb.") {
                remapped["head." + k] = v
            } else if k.hasPrefix("scorer.0.") {
                let rest = k.dropFirst("scorer.0.".count)
                remapped["head.scorer.norm.\(rest)"] = v
            } else if k.hasPrefix("scorer.1.") {
                let rest = k.dropFirst("scorer.1.".count)
                remapped["head.scorer.dense.\(rest)"] = v
            } else if k.hasPrefix("scorer.3.") {
                let rest = k.dropFirst("scorer.3.".count)
                remapped["head.scorer.out.\(rest)"] = v
            } else if k.hasPrefix("encoder.") || k.hasPrefix("head.") {
                remapped[k] = v
            }
        }

        let moduleParams = ModuleParameters.unflattened(remapped)
        _ = try self.update(parameters: moduleParams, verify: .none)
    }

    public func evaluate(
        inputIds: [Int],
        attentionMask: [Int]? = nil,
        markerPositions: [Int],
        questionType: String
    ) -> LayaPrediction {
        let seqLen = inputIds.count
        let inputTensor = MLXArray(inputIds.map { Int32($0) }).reshaped([1, seqLen])
        let maskTensor: MLXArray? = attentionMask != nil ? MLXArray(attentionMask!.map { Int32($0) }).reshaped([1, seqLen]) : nil

        let h = encoder(inputIds: inputTensor, attentionMask: maskTensor)

        let qtypeIdx: Int
        switch questionType {
        case "choice": qtypeIdx = 0
        case "score": qtypeIdx = 1
        case "noul": qtypeIdx = 2
        default: qtypeIdx = 0
        }

        let rawLogitsTensor = head(
            hiddenStates: h,
            attentionMask: maskTensor,
            markerPositions: [markerPositions],
            questionType: qtypeIdx
        )

        // Evaluate on device
        eval(rawLogitsTensor)

        let rawLogits = rawLogitsTensor[0].asArray(Float.self)
        let optionCount = markerPositions.count
        let validLogits = Array(rawLogits.prefix(optionCount))

        let temp = Calibration.temperature(qtype: questionType, optionCount: optionCount, config: config)
        let scaledLogits = validLogits.map { $0 / temp }
        let probs = Calibration.softmax(scaledLogits)
        let conf = Calibration.confidence(probabilities: probs)

        var bestIdx = 0
        var bestProb: Float = -1.0
        for (i, p) in probs.enumerated() {
            if p > bestProb {
                bestProb = p
                bestIdx = i
            }
        }

        let expScore = questionType == "score" ? Calibration.expectedScore(probabilities: probs) : nil

        return LayaPrediction(
            qtype: questionType,
            logits: validLogits,
            probabilities: probs,
            confidence: conf,
            topChoiceIndex: bestIdx,
            expectedScore: expScore
        )
    }
}
