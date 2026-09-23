import XCTest
@testable import PpCore

final class AppAliasTests: XCTestCase {

    let installedApps = [
        "Zen",
        "Google Chrome",
        "Visual Studio Code",
        "WhatsApp",
        "Messages",
        "Terminal",
        "Notes",
        "Finder",
        "Safari",
        "Photos",
        "Music",
        "Calendar",
        "Mail",
        "Slack",
        "System Settings"
    ]

    func testBuiltInAliases() {
        XCTAssertEqual(AppNameMatcher.match("zen", against: installedApps), "Zen")
        XCTAssertEqual(AppNameMatcher.match("chrome", against: installedApps), "Google Chrome")
        XCTAssertEqual(AppNameMatcher.match("code", against: installedApps), "Visual Studio Code")
        XCTAssertEqual(AppNameMatcher.match("vs code", against: installedApps), "Visual Studio Code")
        XCTAssertEqual(AppNameMatcher.match("whatsapp", against: installedApps), "WhatsApp")
        XCTAssertEqual(AppNameMatcher.match("messages", against: installedApps), "Messages")
        XCTAssertEqual(AppNameMatcher.match("terminal", against: installedApps), "Terminal")
        XCTAssertEqual(AppNameMatcher.match("notes", against: installedApps), "Notes")
        XCTAssertEqual(AppNameMatcher.match("finder", against: installedApps), "Finder")
        XCTAssertEqual(AppNameMatcher.match("safari", against: installedApps), "Safari")
    }

    func testSpelledOutLettersCollapse() {
        XCTAssertEqual(AppNameMatcher.match("z e n", against: installedApps), "Zen")
        XCTAssertEqual(AppNameMatcher.match("s a f a r i", against: installedApps), "Safari")
        XCTAssertEqual(AppNameMatcher.match("n o t e s", against: installedApps), "Notes")
        XCTAssertEqual(AppNameMatcher.match("c h r o m e", against: installedApps), "Google Chrome")
    }

    func testSafeFuzzyMatching() {
        // One-edit distance on names >= 4 characters
        XCTAssertEqual(AppNameMatcher.match("safar", against: installedApps), "Safari") // missing last letter
        XCTAssertEqual(AppNameMatcher.match("safarii", against: installedApps), "Safari") // extra letter
        XCTAssertEqual(AppNameMatcher.match("slackk", against: installedApps), "Slack") // extra letter

        // Short words (< 4 chars) MUST NOT fuzzy match
        let shortApps = ["Go", "Zen"]
        XCTAssertNil(AppNameMatcher.match("zo", against: shortApps)) // edit distance 1 from Zen, but length 2 < 4
        XCTAssertNil(AppNameMatcher.match("zn", against: shortApps)) // edit distance 1 from Zen (missing middle letter), but length 2 < 4
    }

    func testAmbiguityResolvesToNil() {
        let ambiguousApps = ["Firefox Developer Edition", "Firefox Nightly"]
        XCTAssertNil(AppNameMatcher.match("firefox", against: ambiguousApps), "Ambiguity between two matches must return nil")
    }

    func testUserCustomAliases() {
        let aliases = AppAliases.shared
        aliases.setUserAlias(alias: "my browser", target: "Zen")
        defer { aliases.removeUserAlias(alias: "my browser") }

        XCTAssertEqual(AppNameMatcher.match("my browser", against: installedApps), "Zen")
    }
}
