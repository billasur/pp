import XCTest
@testable import PpCore

final class SystemIntentTests: XCTestCase {
    func testVolumeParsingAndWordFractions() {
        // "turn up the volume" without number defaults to .up(10)
        XCTAssertEqual(SystemIntentParser.parse("turn up the volume"), .volume(.up(10)))
        XCTAssertEqual(SystemIntentParser.parse("turn down the volume"), .volume(.down(10)))

        // Word fractions and percentages
        XCTAssertEqual(SystemIntentParser.parse("volume to fifty percent"), .volume(.absolute(50)))
        XCTAssertEqual(SystemIntentParser.parse("set volume to a quarter"), .volume(.absolute(25)))
        XCTAssertEqual(SystemIntentParser.parse("volume half"), .volume(.absolute(50)))
        XCTAssertEqual(SystemIntentParser.parse("mute"), .volume(.mute))
        XCTAssertEqual(SystemIntentParser.parse("unmute"), .volume(.unmute))
    }

    func testBrightnessParsing() {
        XCTAssertEqual(SystemIntentParser.parse("set brightness to 80%"), .brightness(percent: 80))
        XCTAssertEqual(SystemIntentParser.parse("brightness half"), .brightness(percent: 50))
    }

    func testSystemLanes() {
        XCTAssertEqual(SystemIntentParser.parse("turn on dark mode"), .darkMode(enabled: true))
        XCTAssertEqual(SystemIntentParser.parse("light mode"), .darkMode(enabled: false))

        XCTAssertEqual(SystemIntentParser.parse("turn on do not disturb"), .doNotDisturb(enabled: true))
        XCTAssertEqual(SystemIntentParser.parse("dnd off"), .doNotDisturb(enabled: false))

        XCTAssertEqual(SystemIntentParser.parse("lock screen"), .lockScreen)
        XCTAssertEqual(SystemIntentParser.parse("sleep display"), .sleepDisplay)
        XCTAssertEqual(SystemIntentParser.parse("start screen saver"), .screenSaver)
        XCTAssertEqual(SystemIntentParser.parse("take a screenshot"), .screenshot)
        XCTAssertEqual(SystemIntentParser.parse("empty trash"), .emptyTrash)
        XCTAssertEqual(SystemIntentParser.parse("turn on wifi"), .wifi(enabled: true))
        XCTAssertEqual(SystemIntentParser.parse("turn off bluetooth"), .bluetooth(enabled: false))
        XCTAssertEqual(SystemIntentParser.parse("pause music"), .music(action: "pause music"))
        XCTAssertEqual(SystemIntentParser.parse("open settings"), .openSettings(pane: nil))
        XCTAssertEqual(SystemIntentParser.parse("open sound settings"), .openSettings(pane: "sound"))
    }
}
