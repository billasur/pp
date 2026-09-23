import XCTest
@testable import PpCore

final class WakeMatcherTests: XCTestCase {

    func testWakeMatcherExactAndPhoneticVariants() {
        let positiveCases: [(String, String)] = [
            ("hey pp open zen", "open zen"),
            ("Hey pp, open zen", "open zen"),
            ("HEY PP OPEN ZEN", "OPEN ZEN"),
            ("ey pp open zen", "open zen"),
            ("Ey pp, open zen", "open zen"),
            ("heipp open zen", "open zen"),
            ("heypp open zen", "open zen"),
            ("heypp, open zen", "open zen"),
            ("hey p p open zen", "open zen"),
            ("hey pee pee open zen", "open zen"),
            ("a pp open zen", "open zen"),
            ("hey bee open zen", "open zen"),
            ("hey papa open zen", "open zen"),
            ("hay pp open zen", "open zen"),
            ("hei pp open zen", "open zen"),
            ("hi pp open zen", "open zen"),
            ("heypee open zen", "open zen"),
            ("hepp open zen", "open zen"),
            ("hey peep open zen", "open zen"),
            ("hey peepy open zen", "open zen"),
            ("hey pip open zen", "open zen"),
            ("hey pop open zen", "open zen"),
            ("okay hey pp open zen", "open zen"),
            ("um hey pp open zen", "open zen"),
            ("so hey pp open zen", "open zen"),
            ("well hey pp open zen", "open zen"),
            ("pp open zen", "open zen"),
            ("p p open zen", "open zen"),
            ("pp, open zen", "open zen"),
            ("hey pp search youtube.com", "search youtube.com"),
            ("hey pp set an alarm for seven thirty", "set an alarm for seven thirty"),
            ("hey pp whatsapp diya", "whatsapp diya"),
            ("heyyy pp open zen", "open zen"),
            ("hey pppp open zen", "open zen"),
            ("hey peeee open zen", "open zen"),
            ("hey pp", ""),
            ("heipp", ""),
            ("hey p p", ""),
            ("ey pp", "")
        ]

        for (input, expectedCommand) in positiveCases {
            guard let match = WakeMatcher.match(in: input) else {
                XCTFail("Expected '\(input)' to match wake phrase")
                continue
            }
            XCTAssertEqual(match.command, expectedCommand, "Mismatch for input '\(input)'")
        }
    }

    func testWakeMatcherNegatives() {
        let negativeCases = [
            "hey buddy",
            "open pp",
            "heyyy",
            "hey",
            "hello world",
            "stop the music",
            "pplication open",
            "hey someone said pp",
            "this is a test hey pp open zen" // wake phrase is past the first 4 tokens
        ]

        for input in negativeCases {
            let match = WakeMatcher.match(in: input)
            XCTAssertNil(match, "Expected '\(input)' NOT to match wake phrase, but got \(String(describing: match))")
        }
    }
}
