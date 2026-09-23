import XCTest
@testable import PpCore

final class WakeSessionTests: XCTestCase {

    func testWakeAnywhereInFirstFourWords() {
        var session = WakeSession(initialPhase: .wakeListening)
        
        // At start (word 0)
        let outcome1 = session.ingest(partial: "hey pp open zen", at: 1.0)
        XCTAssertEqual(outcome1, .woke(command: "open zen"))
        XCTAssertEqual(session.phase, .session)

        // At word 1 ("okay hey pp")
        session.armForWake()
        let outcome2 = session.ingest(partial: "okay hey pp open zen", at: 2.0)
        XCTAssertEqual(outcome2, .woke(command: "open zen"))
        XCTAssertEqual(session.phase, .session)

        // At word 2 ("um so hey pp open zen")
        session.armForWake()
        let outcome3 = session.ingest(partial: "um so hey pp open zen", at: 3.0)
        XCTAssertEqual(outcome3, .woke(command: "open zen"))
        XCTAssertEqual(session.phase, .session)
    }

    func testBareWakeThenCommandTwoSecondsLaterStaysInSession() {
        var session = WakeSession(initialPhase: .wakeListening)

        // Bare wake
        let outcome = session.ingest(partial: "hey pp", at: 10.0)
        XCTAssertEqual(outcome, .woke(command: ""))
        XCTAssertEqual(session.phase, .session)

        // Bare wake clause completed
        let clause1 = session.clauseCompleted("hey pp", at: 10.5)
        XCTAssertEqual(clause1, .none)
        XCTAssertEqual(session.phase, .session)

        // 2 seconds later, command arrives
        let outcome2 = session.ingest(partial: "open zen", at: 12.5)
        XCTAssertEqual(outcome2, .inSession(partial: "open zen"))

        let clause2 = session.clauseCompleted("open zen", at: 13.0)
        XCTAssertEqual(clause2, .execute("open zen"))
        XCTAssertEqual(session.phase, .session)
    }

    func testThreeClausesInOneSessionExecuteInOrder() {
        var session = WakeSession(initialPhase: .wakeListening)

        // Wake
        _ = session.ingest(partial: "hey pp", at: 1.0)
        _ = session.clauseCompleted("hey pp", at: 1.5)

        // Clause 1
        _ = session.ingest(partial: "open zen", at: 3.0)
        let action1 = session.clauseCompleted("open zen", at: 4.0)
        XCTAssertEqual(action1, .execute("open zen"))
        XCTAssertEqual(session.phase, .session)

        // Clause 2
        _ = session.ingest(partial: "open youtube.com", at: 6.0)
        let action2 = session.clauseCompleted("open youtube.com", at: 7.0)
        XCTAssertEqual(action2, .execute("open youtube.com"))
        XCTAssertEqual(session.phase, .session)

        // Clause 3
        _ = session.ingest(partial: "search youtube for lofi beats", at: 9.0)
        let action3 = session.clauseCompleted("search youtube for lofi beats", at: 10.0)
        XCTAssertEqual(action3, .execute("search youtube for lofi beats"))
        XCTAssertEqual(session.phase, .session)

        // "bye" closes
        let actionClose = session.clauseCompleted("bye", at: 12.0)
        XCTAssertEqual(actionClose, .close)
        XCTAssertEqual(session.phase, .closing)
    }

    func testDismissalClosing() {
        var session = WakeSession(initialPhase: .session, initialTime: 10.0)

        // Ingest dismissal
        let outcome = session.ingest(partial: "bye", at: 11.0)
        XCTAssertEqual(outcome, .dismissed)
        XCTAssertEqual(session.phase, .closing)

        // Another session with "goodbye"
        var session2 = WakeSession(initialPhase: .session, initialTime: 10.0)
        let action = session2.clauseCompleted("goodbye", at: 11.0)
        XCTAssertEqual(action, .close)
        XCTAssertEqual(session2.phase, .closing)
    }

    func testStopTheMusicDoesNotClose() {
        var session = WakeSession(initialPhase: .session, initialTime: 10.0)

        let outcome = session.ingest(partial: "stop the music", at: 11.0)
        XCTAssertEqual(outcome, .inSession(partial: "stop the music"))
        XCTAssertEqual(session.phase, .session)

        let action = session.clauseCompleted("stop the music", at: 12.0)
        XCTAssertEqual(action, .execute("stop the music"))
        XCTAssertEqual(session.phase, .session)
    }

    func testIdleTimeoutCloses() {
        var session = WakeSession(sessionIdleSeconds: 300.0, initialPhase: .session, initialTime: 100.0)

        // Before timeout
        XCTAssertFalse(session.checkTimeout(at: 399.0))
        XCTAssertEqual(session.phase, .session)

        // At or after timeout (100 + 300 = 400)
        XCTAssertTrue(session.checkTimeout(at: 400.0))
        XCTAssertEqual(session.phase, .closing)
    }

    func testEscapeOrCloseMethodCloses() {
        var session = WakeSession(initialPhase: .session, initialTime: 10.0)
        session.close()
        XCTAssertEqual(session.phase, .closing)
    }
}
