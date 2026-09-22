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

    public static func buildSequence(
        tokenizer: SequenceTokenizer,
        state: Any,
        question: [String: Any],
        maxLen: Int = 512,
        headMaxLen: Int = 192,
        optionOrder: [Int]? = nil,
        truncateLeft: Bool = false
    ) -> BuiltSequence {
        let maskTok = tokenizer.maskToken
        let opts = renderOptions(question: question)
        let order = optionOrder ?? Array(0..<opts.count)

        let insRaw = "\(question["ins"] ?? "")"
        let ins = insRaw.replacingOccurrences(of: maskTok, with: " ")
        let qType = question["t"] as? String ?? "choice"

        var headIds = tokenizer.encode("\(qType) question: \(ins)")
        var optIds: [[Int]] = []

        for i in order {
            let optText = opts[i].replacingOccurrences(of: maskTok, with: " ")
            let encodedOpt = tokenizer.encode(" " + optText)
            let trimmedOpt = Array(encodedOpt.prefix(48))
            optIds.append([tokenizer.maskTokenId] + trimmedOpt)
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

        let st: [Int]
        if truncateLeft {
            st = Array(stateIds.suffix(room))
        } else {
            st = Array(stateIds.prefix(room))
        }

        ids.append(contentsOf: st)
        ids.append(tokenizer.sepTokenId)

        let finalIds = Array(ids.prefix(maxLen))
        let finalMarkers = markers.filter { $0 < maxLen }

        let orderedOptions = order.map { opts[$0] }
        return BuiltSequence(inputIds: finalIds, markers: finalMarkers, options: orderedOptions)
    }
}
