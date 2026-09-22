import XCTest
@testable import PpCore

final class SafetyCriticTests: XCTestCase {
    func testSafeActionsAreAllowed() {
        let safe1 = SafetyCritic.evaluate(actionLabel: "Search button", actionDetail: "Click to search", command: "search for cats", confidence: 0.95)
        XCTAssertEqual(safe1, .safe)

        let safe2 = SafetyCritic.evaluate(actionLabel: "Scroll down", actionDetail: "", command: "scroll down", confidence: 0.8)
        XCTAssertEqual(safe2, .safe)
    }

    func testDestructiveActionsRequireConfirmation() {
        let deleteAction = SafetyCritic.evaluate(actionLabel: "Delete File", actionDetail: "Permanently delete file", command: "delete this note", confidence: 0.70)
        XCTAssertTrue(deleteAction.isBlocked)
        if case .requiresConfirmation(let category, _) = deleteAction {
            XCTAssertEqual(category, .destructive)
        } else {
            XCTFail("Expected requiresConfirmation for delete")
        }
    }

    func testOutwardTransmissionRequiresConfirmation() {
        let sendAction = SafetyCritic.evaluate(actionLabel: "Send Message", actionDetail: "Submit message to room", command: "send hello", confidence: 0.65)
        XCTAssertTrue(sendAction.isBlocked)
        if case .requiresConfirmation(let category, _) = sendAction {
            XCTAssertEqual(category, .outwardTransmission)
        } else {
            XCTFail("Expected requiresConfirmation for send")
        }
    }

    func testFinancialTransactionRequiresConfirmation() {
        let buyAction = SafetyCritic.evaluate(actionLabel: "Buy Now", actionDetail: "Complete $49 checkout", command: "buy the shoes", confidence: 0.99)
        XCTAssertTrue(buyAction.isBlocked)
        if case .requiresConfirmation(let category, _) = buyAction {
            XCTAssertEqual(category, .financialTransaction)
        } else {
            XCTFail("Expected requiresConfirmation for buy")
        }
    }

    func testSystemModificationRequiresConfirmation() {
        let rebootAction = SafetyCritic.evaluate(actionLabel: "Reboot System", actionDetail: "Reboot the mac", command: "reboot now", confidence: 0.95)
        XCTAssertTrue(rebootAction.isBlocked)
        if case .requiresConfirmation(let category, _) = rebootAction {
            XCTAssertEqual(category, .systemControl)
        } else {
            XCTFail("Expected requiresConfirmation for system modification")
        }
    }

    func testPlanStepEvaluation() {
        let step = PlanStep(kind: .click, target: "Checkout and Pay button")
        let verdict = SafetyCritic.evaluate(step: step, goal: "pay for order")
        XCTAssertTrue(verdict.isBlocked)
    }
}
