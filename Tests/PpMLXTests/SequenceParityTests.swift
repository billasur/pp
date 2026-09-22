import XCTest
import Foundation
@testable import PpMLX

final class SequenceParityTests: XCTestCase {

    struct MockTokenizer: SequenceTokenizer {
        let clsTokenId = 50281
        let sepTokenId = 50282
        let padTokenId = 50283
        let maskTokenId = 50284
        let maskToken = "[MASK]"

        func encode(_ text: String) -> [Int] {
            // Deterministic word-hash tokenizer for sequence builder unit testing
            let words = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            return words.map { abs($0.hashValue % 40000) + 100 }
        }
    }

    func testSequenceBuilderBudgetCaps() {
        let tokenizer = MockTokenizer()
        let state = "Application: Safari, Title: Wikipedia"
        let question: [String: Any] = [
            "t": "choice",
            "inst": "Which tab should be selected?",
            "crit": [
                "tab1": "Search Wikipedia",
                "tab2": "Close Tab"
            ]
        ]

        let built = SequenceBuilder.buildSequence(
            tokenizer: tokenizer,
            state: state,
            question: question,
            maxLen: 512
        )

        XCTAssertEqual(built.markers.count, 2, "Choice question with 2 options must produce 2 markers")
        XCTAssertEqual(built.options.count, 2)
        XCTAssertTrue(built.inputIds.first == tokenizer.clsTokenId)
        XCTAssertTrue(built.inputIds.last == tokenizer.sepTokenId)
        XCTAssertLessThanOrEqual(built.inputIds.count, 512)
    }

    func testCalibrationTemperatures() {
        let config = ModernBertConfig.layaDefault
        let tChoice2 = Calibration.temperature(qtype: "choice", optionCount: 2, config: config)
        let tChoice5 = Calibration.temperature(qtype: "choice", optionCount: 5, config: config)
        let tChoice8 = Calibration.temperature(qtype: "choice", optionCount: 8, config: config)
        let tChoice15 = Calibration.temperature(qtype: "choice", optionCount: 15, config: config)
        let tNoul2 = Calibration.temperature(qtype: "noul", optionCount: 2, config: config)
        let tScore = Calibration.temperature(qtype: "score", optionCount: 1, config: config)

        XCTAssertEqual(tChoice2, 1.9063563, accuracy: 1e-4)
        XCTAssertEqual(tChoice5, 1.7601519, accuracy: 1e-4)
        XCTAssertEqual(tChoice8, 1.0000159, accuracy: 1e-4)
        XCTAssertEqual(tChoice15, 0.1005828, accuracy: 1e-4)
        XCTAssertEqual(tNoul2, 1.9833995, accuracy: 1e-4)
        XCTAssertEqual(tScore, 1.2514300, accuracy: 1e-4)
    }

    func testSoftmaxAndEntropy() {
        let logits: [Float] = [1.0, 2.0, 3.0]
        let probs = Calibration.softmax(logits)
        let sum = probs.reduce(0, +)
        XCTAssertEqual(sum, 1.0, accuracy: 1e-5)
        XCTAssertTrue(probs[2] > probs[1] && probs[1] > probs[0])

        let conf = Calibration.confidence(probabilities: probs)
        XCTAssertGreaterThanOrEqual(conf, 0.0)
        XCTAssertLessThanOrEqual(conf, 1.0)
    }
}
