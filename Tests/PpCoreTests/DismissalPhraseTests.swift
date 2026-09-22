import XCTest
@testable import PpCore

final class DismissalPhraseTests: XCTestCase {
    func testHardCancelsEqualEscape() {
        XCTAssertEqual(DismissalPhrase.match("stop"), .cancel)
        XCTAssertEqual(DismissalPhrase.match("Stop!"), .cancel)
        XCTAssertEqual(DismissalPhrase.match("cancel"), .cancel)
        XCTAssertEqual(DismissalPhrase.match("  Cancel.  "), .cancel)
    }

    func testPoliteDismissals() {
        XCTAssertEqual(DismissalPhrase.match("thank you"), .dismiss)
        XCTAssertEqual(DismissalPhrase.match("Thank you!"), .dismiss)
        XCTAssertEqual(DismissalPhrase.match("thanks"), .dismiss)
        XCTAssertEqual(DismissalPhrase.match("that's all"), .dismiss)
        XCTAssertEqual(DismissalPhrase.match("nevermind"), .dismiss)
        XCTAssertEqual(DismissalPhrase.match("dismiss"), .dismiss)
        XCTAssertEqual(DismissalPhrase.match("go away"), .dismiss)
    }

    func testNegativePhrasesAreNotDismissals() {
        // Essential negative tests: commands containing "stop", "cancel", "thank you"
        XCTAssertNil(DismissalPhrase.match("stop the music"))
        XCTAssertNil(DismissalPhrase.match("cancel my subscription"))
        XCTAssertNil(DismissalPhrase.match("thank you for the notes"))
        XCTAssertNil(DismissalPhrase.match("stop playing"))
        XCTAssertNil(DismissalPhrase.match("cancel the meeting on Tuesday"))
        XCTAssertNil(DismissalPhrase.match("open Notes and thank you"))
    }
}
