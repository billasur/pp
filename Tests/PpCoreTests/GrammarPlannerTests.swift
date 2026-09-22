import XCTest
@testable import PpCore

final class GrammarPlannerTests: XCTestCase {
    func testSingleActionClauses() {
        let appPlan = GrammarPlanner.plan(utterance: "open Safari")
        XCTAssertEqual(appPlan.count, 1)
        XCTAssertEqual(appPlan[0].kind, .openApp)
        XCTAssertEqual(appPlan[0].target, "Safari")

        let folderPlan = GrammarPlanner.plan(utterance: "open Downloads folder")
        XCTAssertEqual(folderPlan.count, 1)
        XCTAssertEqual(folderPlan[0].kind, .openFolder)
        XCTAssertEqual(folderPlan[0].target, "Downloads")

        let urlPlan = GrammarPlanner.plan(utterance: "go to github.com")
        XCTAssertEqual(urlPlan.count, 1)
        XCTAssertEqual(urlPlan[0].kind, .openURL)
        XCTAssertEqual(urlPlan[0].target, "https://github.com")

        let quitPlan = GrammarPlanner.plan(utterance: "quit Slack")
        XCTAssertEqual(quitPlan.count, 1)
        XCTAssertEqual(quitPlan[0].kind, .quitApp)
        XCTAssertEqual(quitPlan[0].target, "Slack")

        let scrollPlan = GrammarPlanner.plan(utterance: "scroll down 3 times")
        XCTAssertEqual(scrollPlan.count, 1)
        XCTAssertEqual(scrollPlan[0].kind, .scroll)
        XCTAssertEqual(scrollPlan[0].target, "down")
        XCTAssertEqual(scrollPlan[0].amount, 3)

        let menuPlan = GrammarPlanner.plan(utterance: "close the window")
        XCTAssertEqual(menuPlan.count, 1)
        XCTAssertEqual(menuPlan[0].kind, .menu)
        XCTAssertEqual(menuPlan[0].target, "Close Window")
    }

    func testCompoundClauses() {
        // "and then" compound
        let compound = GrammarPlanner.plan(utterance: "open Terminal and then run git status")
        XCTAssertEqual(compound.count, 4) // open Terminal, open Terminal (from run), typeText "git status", pressKey return
        XCTAssertEqual(compound[0].kind, .openApp)
        XCTAssertEqual(compound[0].target, "Terminal")

        // Search query
        let search = GrammarPlanner.plan(utterance: "search for Apple Silicon")
        XCTAssertEqual(search.count, 3)
        XCTAssertEqual(search[0].kind, .openURL)
        XCTAssertTrue(search[0].target?.contains("Apple%20Silicon") == true || search[0].target?.contains("Apple+Silicon") == true || search[0].target?.contains("google") == true)
        XCTAssertEqual(search[1].kind, .focusInput)
        XCTAssertEqual(search[2].kind, .typeText)
        XCTAssertEqual(search[2].text, "Apple Silicon")
    }

    func testTypeIntoInput() {
        let typed = GrammarPlanner.plan(utterance: "type 'hello world' into Search box")
        XCTAssertEqual(typed.count, 2)
        XCTAssertEqual(typed[0].kind, .focusInput)
        XCTAssertEqual(typed[0].target, "Search box")
        XCTAssertEqual(typed[1].kind, .typeText)
        XCTAssertEqual(typed[1].text, "hello world")
    }
}
