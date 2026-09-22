import Foundation

public enum Calibration {
    public static func tempBucket(qtype: String, optionCount: Int) -> String {
        switch qtype {
        case "noul":
            return optionCount == 2 ? "noul:2" : "noul:\(optionCount)"
        case "score":
            if optionCount >= 3 && optionCount <= 5 {
                return "score:3-5"
            }
            return "score:\(optionCount)"
        case "choice":
            if optionCount <= 2 {
                return "choice:2"
            } else if optionCount <= 5 {
                return "choice:3-5"
            } else if optionCount <= 10 {
                return "choice:6-10"
            } else {
                return "choice:11+"
            }
        default:
            return "\(qtype):\(optionCount)"
        }
    }

    public static func temperature(
        qtype: String,
        optionCount: Int,
        config: ModernBertConfig
    ) -> Float {
        let bucket = tempBucket(qtype: qtype, optionCount: optionCount)
        if let temp = config.temperatureByOptions[bucket] {
            return temp
        }
        let qtypeIdx: Int
        switch qtype {
        case "choice": qtypeIdx = 0
        case "score": qtypeIdx = 1
        case "noul": qtypeIdx = 2
        default: qtypeIdx = 0
        }
        if qtypeIdx < config.defaultTemperature.count {
            return config.defaultTemperature[qtypeIdx]
        }
        return 1.0
    }

    public static func softmax(_ logits: [Float]) -> [Float] {
        guard !logits.isEmpty else { return [] }
        let maxVal = logits.max() ?? 0.0
        var exps = [Float](repeating: 0.0, count: logits.count)
        var sumExp: Float = 0.0
        for i in 0..<logits.count {
            let e = exp(logits[i] - maxVal)
            exps[i] = e
            sumExp += e
        }
        if sumExp <= 0.0 { sumExp = 1.0 }
        return exps.map { $0 / sumExp }
    }

    public static func confidence(probabilities: [Float]) -> Float {
        let k = max(2, probabilities.count)
        let logK = log(Float(k))
        var entropy: Float = 0.0
        for p in probabilities {
            let clampedP = max(1e-9, p)
            entropy -= clampedP * log(clampedP)
        }
        let normalizedEntropy = entropy / logK
        return max(0.0, min(1.0, 1.0 - normalizedEntropy))
    }

    public static func expectedScore(probabilities: [Float]) -> Float {
        var score: Float = 0.0
        for (idx, p) in probabilities.enumerated() {
            score += Float(idx) * p
        }
        return score
    }
}
