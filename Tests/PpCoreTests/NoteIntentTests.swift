import XCTest
@testable import PpCore

final class NoteIntentTests: XCTestCase {
    func testTaskCreationUtterances() {
        let task1 = NoteIntentParser.parse("create new task in the notes app")
        XCTAssertEqual(task1, .create(text: "", isTask: true))

        let task2 = NoteIntentParser.parse("create a task in notes")
        XCTAssertEqual(task2, .create(text: "", isTask: true))

        let task3 = NoteIntentParser.parse("create new task in the notes app buy groceries")
        XCTAssertEqual(task3, .create(text: "buy groceries", isTask: true))

        let task4 = NoteIntentParser.parse("create a task in notes to call dentist")
        XCTAssertEqual(task4, .create(text: "call dentist", isTask: true))
    }

    func testNoteCreationUtterances() {
        let note1 = NoteIntentParser.parse("create new note in the notes app")
        XCTAssertEqual(note1, .create(text: "", isTask: false))

        let note2 = NoteIntentParser.parse("new note in notes")
        XCTAssertEqual(note2, .create(text: "", isTask: false))

        let note3 = NoteIntentParser.parse("make a note in notes meeting summary")
        XCTAssertEqual(note3, .create(text: "meeting summary", isTask: false))
    }

    func testHeadingChangeUtterances() {
        let h1 = NoteIntentParser.parse("change the heading to Q3 Product Roadmap")
        XCTAssertEqual(h1, .changeHeading(to: "Q3 Product Roadmap"))

        let h2 = NoteIntentParser.parse("change title to Sprint Planning")
        XCTAssertEqual(h2, .changeHeading(to: "Sprint Planning"))

        let h3 = NoteIntentParser.parse("set heading to Daily Standup")
        XCTAssertEqual(h3, .changeHeading(to: "Daily Standup"))
    }

    func testLineChangeUtterances() {
        let l1 = NoteIntentParser.parse("change this line to Deploying to production")
        XCTAssertEqual(l1, .changeCurrentLine(to: "Deploying to production"))

        let l2 = NoteIntentParser.parse("replace this line with Finished documentation")
        XCTAssertEqual(l2, .changeCurrentLine(to: "Finished documentation"))
    }

    func testTextReplacementUtterances() {
        let r1 = NoteIntentParser.parse("replace draft with final")
        XCTAssertEqual(r1, .replaceText(target: "draft", replacement: "final"))
    }

    func testCommandRouterIntegration() {
        let route1 = CommandRouter.route(text: "create new task in the notes app")
        XCTAssertEqual(route1.lane, .note)

        let route2 = CommandRouter.route(text: "change the heading to Architecture Spec")
        XCTAssertEqual(route2.lane, .note)

        let route3 = CommandRouter.route(text: "change this line to Verified on Mac")
        XCTAssertEqual(route3.lane, .note)
    }
}
