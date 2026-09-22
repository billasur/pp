import Foundation

public protocol SequenceTokenizer {
    var clsTokenId: Int { get }
    var sepTokenId: Int { get }
    var padTokenId: Int { get }
    var maskTokenId: Int { get }
    var maskToken: String { get }
    func encode(_ text: String) -> [Int]
}

public struct BuiltSequence: Equatable {
    public let inputIds: [Int]
    public let markers: [Int]
    public let options: [String]

    public init(inputIds: [Int], markers: [Int], options: [String]) {
        self.inputIds = inputIds
        self.markers = markers
        self.options = options
    }
}

public enum SequenceBuilder {
    public static func serializeState(_ state: Any) -> String {
        if let s = state as? String {
            return s
        }
        if JSONSerialization.isValidJSONObject(state),
           let data = try? JSONSerialization.data(withJSONObject: state, options: [.fragmentsAllowed]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "\(state)"
    }

    public static func renderCriterion(_ value: Any?) -> String {
        guard let val = value else { return "" }
        if let s = val as? String {
            return s
        }
        if JSONSerialization.isValidJSONObject(val),
           let data = try? JSONSerialization.data(withJSONObject: val, options: [.fragmentsAllowed]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "\(val)"
    }

    public static func renderOptions(question: [String: Any]) -> [String] {
        guard let t = question["t"] as? String else { return [] }
        let crit = question["crit"]

        if t == "choice" {
            if let critDict = crit as? [String: Any] {
                // In Python, dictionaries preserve insertion order.
                // We should support ordered representation if provided as array of pairs,
                // or sorted/dict keys.
                return critDict.map { k, v in
                    if let s = v as? String, s.isEmpty {
                        return k
                    } else if (v is NSNull) {
                        return k
                    } else {
                        return "\(k): \(renderCriterion(v))"
                    }
                }
            } else if let critPairs = crit as? [[String]] {
                return critPairs.map { pair in
                    let k = pair[0]
                    let v = pair.count > 1 ? pair[1] : ""
                    return v.isEmpty ? k : "\(k): \(v)"
                }
            }
            return []
        }

        if t == "score" {
            if let critList = crit as? [Any] {
                return critList.enumerated().map { i, c in
                    "level \(i): \(renderCriterion(c))"
                }
            }
            return []
        }

        // noul
        let critDict = crit as? [String: Any] ?? [:]
        let falseCrit = critDict["false"]
        let trueCrit = critDict["true"]

        let falseStr: String
        if let fc = falseCrit as? String, !fc.isEmpty {
            falseStr = "false: \(fc)"
        } else if let fc = falseCrit, !(fc is NSNull) {
            falseStr = "false: \(renderCriterion(fc))"
        } else {
            falseStr = "false: no, the statement does not hold"
        }

        let trueStr: String
        if let tc = trueCrit as? String, !tc.isEmpty {
            trueStr = "true: \(tc)"
        } else if let tc = trueCrit, !(tc is NSNull) {
            trueStr = "true: \(renderCriterion(tc))"
        } else {
            trueStr = "true: yes, the statement holds"
        }

        return [falseStr, trueStr]
    }

    /// Builds a sequence from an explicit, ordered option list.
    ///
    /// This is the API every live code path must use. Option order decides what each
    /// decision head's index means, so deriving it from an unordered dictionary would
    /// silently mis-map a chosen index back to a candidate.
    public static func buildSequence(
        tokenizer: SequenceTokenizer,
        state: Any,
        questionType: String,
        instructions: String,
        options: [String],
        maxLen: Int = 512,
        headMaxLen: Int = 192,
        truncateLeft: Bool = false
    ) -> BuiltSequence {
        let maskTok = tokenizer.maskToken
        let ins = instructions.replacingOccurrences(of: maskTok, with: " ")

        var headIds = tokenizer.encode("\(questionType) question: \(ins)")
        var optIds: [[Int]] = []

        for option in options {
            let optText = option.replacingOccurrences(of: maskTok, with: " ")
            let encodedOpt = tokenizer.encode(" " + optText)
            optIds.append([tokenizer.maskTokenId] + Array(encodedOpt.prefix(48)))
        }

        var optBudget = headMaxLen - optIds.reduce(0) { $0 + $1.count }
        if optBudget < 16 {
            let per = max(4, (headMaxLen - 16) / max(1, optIds.count))
            optIds = optIds.map { Array($0.prefix(per)) }
            optBudget = headMaxLen - optIds.reduce(0) { $0 + $1.count }
        }

        headIds = Array(headIds.prefix(max(8, optBudget)))

        var ids: [Int] = [tokenizer.clsTokenId] + headIds + [tokenizer.sepTokenId]
        var markers: [Int] = []

        for opt in optIds {
            markers.append(ids.count)
            ids.append(contentsOf: opt)
        }
        ids.append(tokenizer.sepTokenId)

        let room = max(0, maxLen - ids.count - 1)
        let stateStr = serializeState(state).replacingOccurrences(of: maskTok, with: " ")
        let stateIds = tokenizer.encode(stateStr)
        let st = truncateLeft ? Array(stateIds.suffix(room)) : Array(stateIds.prefix(room))

        ids.append(contentsOf: st)
        ids.append(tokenizer.sepTokenId)

        let finalIds = Array(ids.prefix(maxLen))
        let finalMarkers = markers.filter { $0 < maxLen }
        return BuiltSequence(inputIds: finalIds, markers: finalMarkers, options: options)
    }

    /// Dictionary-based entry point, kept for replay and fixture comparisons.
    ///
    /// `options: nil` preserves the original unordered-dictionary behaviour used by the
    /// parity fixtures. Live paths pass a deterministic order.
    public static func buildSequence(
        tokenizer: SequenceTokenizer,
        state: Any,
        question: [String: Any],
        maxLen: Int = 512,
        headMaxLen: Int = 192,
        optionOrder: [Int]? = nil,
        truncateLeft: Bool = false,
        orderedOptions: [String]? = nil
    ) -> BuiltSequence {
        let qType = question["t"] as? String ?? "choice"
        let ins = "\(question["ins"] ?? "")"

        if let orderedOptions {
            return buildSequence(tokenizer: tokenizer, state: state, questionType: qType,
                                 instructions: ins, options: orderedOptions,
                                 maxLen: maxLen, headMaxLen: headMaxLen, truncateLeft: truncateLeft)
        }

        let opts = renderOptions(question: question)
        let order = optionOrder ?? Array(0..<opts.count)
        let ordered = order.map { opts[$0] }

        let built = buildSequence(tokenizer: tokenizer, state: state, questionType: qType,
                                  instructions: ins, options: ordered,
                                  maxLen: maxLen, headMaxLen: headMaxLen, truncateLeft: truncateLeft)
        return BuiltSequence(inputIds: built.inputIds, markers: built.markers, options: order.map { opts[$0] })
    }
}
