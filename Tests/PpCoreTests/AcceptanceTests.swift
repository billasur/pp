import XCTest
@testable import PpCore

final class AcceptanceTests: XCTestCase {

    struct AcceptanceCase: Decodable {
        let input: String
        let expected_lane: String
    }

    func testAcceptanceBattery() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("fixtures")
            .appendingPathComponent("acceptance.jsonl")

        let data = try Data(contentsOf: fixtureURL)
        let lines = String(decoding: data, as: UTF8.self)
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        XCTAssertFalse(lines.isEmpty, "acceptance.jsonl must contain cases")

        var tested = 0
        for line in lines {
            let decoder = JSONDecoder()
            guard let lineData = line.data(using: .utf8),
                  let testCase = try? decoder.decode(AcceptanceCase.self, from: lineData) else {
                XCTFail("Failed to decode JSONL line: \(line)")
                continue
            }

            let route = CommandRouter.route(text: testCase.input)
            XCTAssertEqual(
                route.lane.rawValue,
                testCase.expected_lane,
                "Lane mismatch for '\(testCase.input)'. Expected \(testCase.expected_lane), got \(route.lane.rawValue)"
            )
            tested += 1
        }

        print("Acceptance battery verified \(tested) cases across all command lanes.")
    }
}
