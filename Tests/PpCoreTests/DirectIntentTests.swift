import XCTest
import PpCore

/// The parser that decides which commands may finish without asking the model.
///
/// Every test here is really the same test: a command only takes the fast path when its
/// words name one target and nothing else. A false positive launches something the user
/// did not ask for, so the negatives matter more than the positives.
final class DirectIntentTests: XCTestCase {

    func testABareVerbAndNameIsDeterministic() {
        XCTAssertEqual(DirectIntentParser.parse("open Notes"), .openApp(name: "notes"))
        XCTAssertEqual(DirectIntentParser.parse("Open Notes."), .openApp(name: "notes"))
        XCTAssertEqual(DirectIntentParser.parse("  open   notes  "), .openApp(name: "notes"))
        XCTAssertEqual(DirectIntentParser.parse("launch Slack"), .openApp(name: "slack"))
        XCTAssertEqual(DirectIntentParser.parse("switch to Calendar"), .openApp(name: "calendar"))
        XCTAssertEqual(DirectIntentParser.parse("open the Notes"), .openApp(name: "notes"))
        XCTAssertEqual(DirectIntentParser.parse("please open Finder"), .openApp(name: "finder"))
        XCTAssertEqual(DirectIntentParser.parse("Hey pp, open Music"), .openApp(name: "music"))
    }

    func testQuittingAnAppIsDeterministicToo() {
        XCTAssertEqual(DirectIntentParser.parse("quit Slack"), .quitApp(name: "slack"))
        XCTAssertEqual(DirectIntentParser.parse("close Safari"), .quitApp(name: "safari"))
    }

    func testAWebAddressIsDeterministic() {
        XCTAssertEqual(DirectIntentParser.parse("open google.com"), .openSite(host: "google.com"))
        XCTAssertEqual(DirectIntentParser.parse("go to the guardian dot com"), .openSite(host: "theguardian.com"))
        XCTAssertEqual(DirectIntentParser.parse("visit news.ycombinator.com"), .openSite(host: "news.ycombinator.com"))
    }

    func testAnythingWithASecondClauseIsNotDeterministic() {
        XCTAssertEqual(DirectIntentParser.parse("open Safari and search for cats"), .none)
        XCTAssertEqual(DirectIntentParser.parse("open Notes then type my list"), .none)
        XCTAssertEqual(DirectIntentParser.parse("open Finder, and open Terminal"), .none)
        XCTAssertFalse(DirectIntentParser.parse("open Mail and delete everything").isDeterministic)
    }

    func testCommandsThatAreNotALaunchAreRefused() {
        XCTAssertEqual(DirectIntentParser.parse("type hello into the field"), .none)
        XCTAssertEqual(DirectIntentParser.parse("search for apple silicon"), .none)
        XCTAssertEqual(DirectIntentParser.parse("click the blue button"), .none)
        XCTAssertEqual(DirectIntentParser.parse("delete every note"), .none)
        XCTAssertEqual(DirectIntentParser.parse("scroll down"), .none)
        XCTAssertEqual(DirectIntentParser.parse(""), .none)
        XCTAssertEqual(DirectIntentParser.parse("open"), .none)
    }

    func testASentenceIsNotAName() {
        // Five words after the verb is a description, not an app name.
        XCTAssertEqual(DirectIntentParser.parse("open the big red settings window"), .none)
        XCTAssertEqual(DirectIntentParser.parse("open the file I edited yesterday"), .none)
    }

    func testCaseAndWordOrderDoNotChangeTheAnswer() {
        XCTAssertEqual(DirectIntentParser.parse("OPEN NOTES"), DirectIntentParser.parse("open notes"))
        XCTAssertEqual(DirectIntentParser.parse("Open  NOTES!").target, "notes")
    }

    func testTheIntentCarriesTheTargetForResolution() {
        XCTAssertEqual(DirectIntentParser.parse("quit Slack").target, "slack")
        XCTAssertEqual(DirectIntentParser.parse("no verb here").target, nil)
    }
}

/// The name matcher that decides whether a spoken name is one app or an ambiguity.
final class AppNameMatcherTests: XCTestCase {

    func testAnExactNameAlwaysWins() {
        XCTAssertEqual(AppNameMatcher.match("notes", against: ["notes", "notes pro"]), "notes")
    }

    func testAUniquePrefixIsEnough() {
        XCTAssertEqual(AppNameMatcher.match("term", against: ["terminal", "notes"]), "terminal")
    }

    func testAnAmbiguousNameResolvesToNothing() {
        XCTAssertNil(AppNameMatcher.match("no", against: ["notes", "notion"]),
                     "two candidates must send the command to the model, not pick one")
    }

    func testAnUnknownOrTooShortNameResolvesToNothing() {
        XCTAssertNil(AppNameMatcher.match("slack", against: ["notes", "terminal"]))
        XCTAssertNil(AppNameMatcher.match("n", against: ["notes"]))
        XCTAssertNil(AppNameMatcher.match("notes", against: []))
    }

    func testMatchingIgnoresCaseAndSurroundingSpace() {
        XCTAssertEqual(AppNameMatcher.match("  Notes ", against: ["notes"]), "notes")
    }
}
