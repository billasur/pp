import XCTest
import Foundation
@testable import PpMLX

final class LayaParityTests: XCTestCase {

    struct Fixture: Decodable {
        let index: Int
        let qid: String
        let bucket: String
        let qtype: String
        let input_ids: [Int]
        let markers: [Int]
        let options: [String]
        let raw_logits: [Float]
        let t_scale: Float
        let confidence: Float
    }

    func loadFixtures() throws -> [Fixture] {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let fixtureUrl = root.appendingPathComponent("fixtures/laya_fixtures.jsonl")
        let data = try Data(contentsOf: fixtureUrl)
        guard let content = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "FixtureError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to decode fixtures as utf8"])
        }

        var fixtures: [Fixture] = []
        let lines = content.split(separator: "\n")
        let decoder = JSONDecoder()
        for line in lines {
            let lineStr = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !lineStr.isEmpty else { continue }
            let fix = try decoder.decode(Fixture.self, from: Data(lineStr.utf8))
            fixtures.append(fix)
        }
        return fixtures
    }

    func testModelParityOnFixtures() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let modelDir = root.appendingPathComponent("models/laya-mlx")
        guard FileManager.default.fileExists(atPath: modelDir.path) else {
            throw XCTSkip("models/laya-mlx not found; run tools/convert_laya.py first")
        }

        let model = try LayaModel.load(from: modelDir)
        let fixtures = try loadFixtures()
        XCTAssertGreaterThan(fixtures.count, 0, "Fixtures must not be empty")

        var top1Matches = 0
        var maxLogitDelta: Float = 0.0
        var totalDelta: Float = 0.0
        var comparedLogits = 0

        // Test across all 410 fixtures
        let sampleSize = fixtures.count

        for fix in fixtures.prefix(sampleSize) {
            let pred = model.evaluate(
                inputIds: fix.input_ids,
                markerPositions: fix.markers,
                questionType: fix.qtype
            )

            // Verify logits count matches marker count
            XCTAssertEqual(pred.logits.count, fix.markers.count)

            // Compare argmax top-1 choice with oracle raw_logits argmax
            let oracleTopIdx = fix.raw_logits.enumerated().max(by: { $0.element < $1.element })!.offset
            if pred.topChoiceIndex == oracleTopIdx {
                top1Matches += 1
            }

            // Compare raw logits
            for (swiftLogit, pyLogit) in zip(pred.logits, fix.raw_logits) {
                let delta = abs(swiftLogit - pyLogit)
                if delta > maxLogitDelta {
                    maxLogitDelta = delta
                }
                totalDelta += delta
                comparedLogits += 1
            }
        }

        let meanDelta = comparedLogits > 0 ? totalDelta / Float(comparedLogits) : 0.0
        let top1Acc = Float(top1Matches) / Float(sampleSize)

        print("==================================================================")
        print("[LayaParity] Evaluated \(sampleSize) fixtures on Apple Silicon Metal:")
        print("  Top-1 Exact Match: \(top1Matches)/\(sampleSize) (\(top1Acc * 100.0)%)")
        print("  Max Logit Delta:   \(maxLogitDelta)")
        print("  Mean Logit Delta:  \(meanDelta)")
        print("==================================================================")

        // Numerical parity assertions: fp16 tolerance across 28 layers
        XCTAssertEqual(top1Matches, sampleSize, "Top-1 choices must match 100% on golden fixtures")
        XCTAssertLessThan(maxLogitDelta, 0.20, "Maximum logit delta must be within fp16 numerical variance (< 0.20)")
        XCTAssertLessThan(meanDelta, 0.02, "Mean logit delta must be tiny (< 0.02)")
    }
}
