import XCTest
import CoreGraphics
@testable import PpCore

final class NotchLayoutTests: XCTestCase {
    func testNotchedDisplayLayout() {
        // Typical 13.6-inch MacBook Air with notch (2560x1664 points scaled to 1470x956 or 1512x982)
        let full = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let visible = CGRect(x: 0, y: 0, width: 1512, height: 948)
        // Menu bar height = 982 - 948 = 34
        // Notch is centered: say x from 676 to 836 (width 160)
        let auxLeft = CGRect(x: 0, y: 948, width: 676, height: 34)
        let auxRight = CGRect(x: 836, y: 948, width: 676, height: 34)

        let geom = ScreenGeometry(
            fullFrame: full,
            visibleFrame: visible,
            auxTopLeft: auxLeft,
            auxTopRight: auxRight,
            hasNotch: true
        )

        let bands = NotchLayout.computeBands(for: geom, inset: 8.0)

        // Menu bar height
        XCTAssertEqual(bands.menuBarHeight, 34.0)

        // Bands must be inside full frame
        XCTAssertTrue(full.contains(bands.leftBand))
        XCTAssertTrue(full.contains(bands.rightBand))

        // Left band inside auxLeft bounds
        XCTAssertGreaterThanOrEqual(bands.leftBand.minX, auxLeft.minX + 8.0)
        XCTAssertLessThanOrEqual(bands.leftBand.maxX, auxLeft.maxX - 8.0)

        // Right band inside auxRight bounds
        XCTAssertGreaterThanOrEqual(bands.rightBand.minX, auxRight.minX + 8.0)
        XCTAssertLessThanOrEqual(bands.rightBand.maxX, auxRight.maxX - 8.0)

        // No overlap between left and right bands
        XCTAssertFalse(bands.leftBand.intersects(bands.rightBand))

        // No overlap with the notch itself (676 .. 836)
        let notchRect = CGRect(x: 676, y: 948, width: 160, height: 34)
        XCTAssertFalse(bands.leftBand.intersects(notchRect))
        XCTAssertFalse(bands.rightBand.intersects(notchRect))
    }

    func testNotchlessDisplayLayoutFallback() {
        // External 4K monitor (e.g. 1920x1080 points) without notch
        let full = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let visible = CGRect(x: 0, y: 0, width: 1920, height: 1056) // 24pt menu bar

        let geom = ScreenGeometry(
            fullFrame: full,
            visibleFrame: visible,
            auxTopLeft: nil,
            auxTopRight: nil,
            hasNotch: false
        )

        let bands = NotchLayout.computeBands(for: geom, inset: 8.0)

        XCTAssertEqual(bands.menuBarHeight, 24.0)
        XCTAssertTrue(full.contains(bands.leftBand))
        XCTAssertTrue(full.contains(bands.rightBand))
        XCTAssertFalse(bands.leftBand.intersects(bands.rightBand))

        // Fallback splits the menu-bar strip into left and right halves
        XCTAssertEqual(bands.leftBand.origin.x, 8.0)
        XCTAssertEqual(bands.leftBand.width, 1920.0 / 2.0 - 16.0)
        XCTAssertEqual(bands.rightBand.origin.x, 1920.0 / 2.0 + 8.0)
        XCTAssertEqual(bands.rightBand.width, 1920.0 / 2.0 - 16.0)
    }

    func testIslandStateAlarmAndHeardDurations() {
        let alarmState = IslandState.alarm
        XCTAssertNil(alarmState.autoHideDuration) // Alarm never auto-hides

        let heardState = IslandState.heard(text: "open zen browser")
        XCTAssertNil(heardState.autoHideDuration) // Live transcript never auto-hides

        let resultState = IslandState.result(text: "Done")
        XCTAssertEqual(resultState.autoHideDuration, 2.5)

        let errorState = IslandState.error(text: "Failed")
        XCTAssertEqual(errorState.autoHideDuration, 6.0)
    }

    func testAnchorsHangOffTheNotchsEdges() {
        let full = CGRect(x: 0, y: 0, width: 1470, height: 956)
        let visible = CGRect(x: 0, y: 0, width: 1470, height: 923)
        let auxLeft = CGRect(x: 0, y: 924, width: 645.5, height: 32)
        let auxRight = CGRect(x: 824.5, y: 924, width: 645.5, height: 32)
        let geom = ScreenGeometry(
            fullFrame: full, visibleFrame: visible,
            auxTopLeft: auxLeft, auxTopRight: auxRight, hasNotch: true)

        let anchors = NotchLayout.anchors(for: geom)

        // The left capsule ends where the notch begins, the right one starts where it ends.
        XCTAssertEqual(anchors.leftEdge, auxLeft.maxX - NotchLayout.defaultGap)
        XCTAssertEqual(anchors.rightEdge, auxRight.minX + NotchLayout.defaultGap)

        // The strip is the menu-bar band beside the notch, touching the top of the screen.
        XCTAssertEqual(anchors.strip.height, 32)
        XCTAssertEqual(anchors.strip.maxY, full.maxY)
        XCTAssertTrue(anchors.hasNotch)

        // Both sides have room for a capsule without reaching the screen edge.
        XCTAssertGreaterThan(anchors.leftRoom, 200)
        XCTAssertGreaterThan(anchors.rightRoom, 200)
    }

    func testAnchorsFallBackToTheCentreOfANotchlessMenuBar() {
        let full = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let visible = CGRect(x: 0, y: 0, width: 1920, height: 1056)
        let geom = ScreenGeometry(fullFrame: full, visibleFrame: visible, hasNotch: false)

        let anchors = NotchLayout.anchors(for: geom)

        XCTAssertFalse(anchors.hasNotch)
        XCTAssertEqual(anchors.leftEdge, 960 - NotchLayout.defaultGap)
        XCTAssertEqual(anchors.rightEdge, 960 + NotchLayout.defaultGap)
        XCTAssertEqual(anchors.strip.height, 24)
        XCTAssertEqual(anchors.strip.maxY, full.maxY)
        XCTAssertEqual(anchors.leftRoom, anchors.rightRoom)
    }
}
