import XCTest
import PpCore

final class PreemptionPolicyTests: XCTestCase {

    func testSecondIdenticalStablePartialFiresFirstDoesNot() {
        var policy = PreemptionPolicy(minimumStableObservations: 2, minimumCharacters: 8, cooldown: 1.5)

        // First observation: should return .wait
        let obs1 = PartialObservation(clause: "open Notes", isFinal: false, monotonicTime: 100.0)
        XCTAssertEqual(policy.observe(obs1), .wait)

        // Second identical observation: should return .preempt
        let obs2 = PartialObservation(clause: "open Notes", isFinal: false, monotonicTime: 100.1)
        XCTAssertEqual(policy.observe(obs2), .preempt(step: PlanStep(kind: .openApp, target: "notes"), clause: "open Notes"))
    }

    func testIsFinalNeverPreempts() {
        var policy = PreemptionPolicy(minimumStableObservations: 1, minimumCharacters: 8)
        let obs = PartialObservation(clause: "open Notes", isFinal: true, monotonicTime: 100.0)
        XCTAssertEqual(policy.observe(obs), .wait)
    }

    func testKindsOutsideAllowlistNeverPreempt() {
        var policy = PreemptionPolicy(minimumStableObservations: 1, minimumCharacters: 4, allowed: [.openApp, .quitApp, .openURL])

        // Commands that map to other kinds or are non-launch should not preempt
        let typeObs = PartialObservation(clause: "type hello", isFinal: false, monotonicTime: 100.0)
        XCTAssertEqual(policy.observe(typeObs), .wait)

        let clickObs = PartialObservation(clause: "click button", isFinal: false, monotonicTime: 100.0)
        XCTAssertEqual(policy.observe(clickObs), .wait)

        // Allowed set without .openApp
        var restrictedPolicy = PreemptionPolicy(minimumStableObservations: 1, minimumCharacters: 4, allowed: [.openURL])
        let appObs = PartialObservation(clause: "open Notes", isFinal: false, monotonicTime: 100.0)
        XCTAssertEqual(restrictedPolicy.observe(appObs), .wait)
    }

    func testNonDeterministicClauseNeverPreempts() {
        var policy = PreemptionPolicy(minimumStableObservations: 1, minimumCharacters: 8)
        let obs = PartialObservation(clause: "open the thing I was looking at", isFinal: false, monotonicTime: 100.0)
        XCTAssertEqual(policy.observe(obs), .wait)
    }

    func testMinimumCharactersEnforced() {
        var policy = PreemptionPolicy(minimumStableObservations: 1, minimumCharacters: 8)
        let shortObs = PartialObservation(clause: "open a", isFinal: false, monotonicTime: 100.0)
        XCTAssertEqual(policy.observe(shortObs), .wait)
    }

    func testNoSecondFireInsideCooldown() {
        var policy = PreemptionPolicy(minimumStableObservations: 1, minimumCharacters: 8, cooldown: 1.5)

        let obs1 = PartialObservation(clause: "open Notes", isFinal: false, monotonicTime: 100.0)
        XCTAssertEqual(policy.observe(obs1), .preempt(step: PlanStep(kind: .openApp, target: "notes"), clause: "open Notes"))

        // Inside cooldown (0.5s later): should wait
        let obs2 = PartialObservation(clause: "open Notes", isFinal: false, monotonicTime: 100.5)
        XCTAssertEqual(policy.observe(obs2), .wait)

        // Even after cooldown, same target should not repeatedly fire
        let obs3 = PartialObservation(clause: "open Notes", isFinal: false, monotonicTime: 102.0)
        XCTAssertEqual(policy.observe(obs3), .wait)
    }

    func testMidSentenceTargetCorrectionReturnsSupersedeOnce() {
        var policy = PreemptionPolicy(minimumStableObservations: 1, minimumCharacters: 8, cooldown: 1.5)

        let obs1 = PartialObservation(clause: "open Notes", isFinal: false, monotonicTime: 100.0)
        XCTAssertEqual(policy.observe(obs1), .preempt(step: PlanStep(kind: .openApp, target: "notes"), clause: "open Notes"))

        // Target changes to Reminders inside cooldown (0.4s later): blocked by cooldown
        let obsInsideCooldown = PartialObservation(clause: "open Reminders", isFinal: false, monotonicTime: 100.4)
        XCTAssertEqual(policy.observe(obsInsideCooldown), .wait)

        // Target changes to Reminders after cooldown (1.6s later): returns .supersede with the new target
        let obs2 = PartialObservation(clause: "open Reminders", isFinal: false, monotonicTime: 101.6)
        XCTAssertEqual(policy.observe(obs2), .supersede(step: PlanStep(kind: .openApp, target: "reminders"), clause: "open Reminders"))

        // Subsequent observations do not repeatedly supersede
        let obs3 = PartialObservation(clause: "open Reminders", isFinal: false, monotonicTime: 103.5)
        XCTAssertEqual(policy.observe(obs3), .wait)

        let obs4 = PartialObservation(clause: "open Safari", isFinal: false, monotonicTime: 104.0)
        XCTAssertEqual(policy.observe(obs4), .wait)
    }

    func testRollingWindowDropsStaleObservationsAfter10s() {
        var policy = PreemptionPolicy(minimumStableObservations: 2, minimumCharacters: 8, cooldown: 1.5)

        // First observation at t = 100.0
        let obs1 = PartialObservation(clause: "open Notes", isFinal: false, monotonicTime: 100.0)
        XCTAssertEqual(policy.observe(obs1), .wait)

        // Gap of 30 seconds (stale entry dropped)
        let obs2 = PartialObservation(clause: "open Notes", isFinal: false, monotonicTime: 130.0)
        XCTAssertEqual(policy.observe(obs2), .wait) // Still wait because obs1 was dropped!

        // Second observation within window (t = 130.2)
        let obs3 = PartialObservation(clause: "open Notes", isFinal: false, monotonicTime: 130.2)
        XCTAssertEqual(policy.observe(obs3), .preempt(step: PlanStep(kind: .openApp, target: "notes"), clause: "open Notes"))
    }

    func testPartialThatStopsMatchingReturnsWait() {
        var policy = PreemptionPolicy(minimumStableObservations: 1, minimumCharacters: 8)

        let obs1 = PartialObservation(clause: "open notes", isFinal: false, monotonicTime: 100.0)
        XCTAssertEqual(policy.observe(obs1), .preempt(step: PlanStep(kind: .openApp, target: "notes"), clause: "open notes"))

        // Appended "and never mind" or conjunction invalidates deterministic direct intent
        let obs2 = PartialObservation(clause: "open notes and never mind", isFinal: false, monotonicTime: 100.5)
        XCTAssertEqual(policy.observe(obs2), .wait)
    }

    func testTakeRemainderExactPrefixAndConnectors() {
        // Exact prefix with trailing connector "and"
        let full1 = "open notes and write down meeting notes"
        let consumed1 = "open notes"
        XCTAssertEqual(PreemptionPolicy.takeRemainder(full: full1, consumed: consumed1), "write down meeting notes")

        // Trailing connector "then"
        let full2 = "open notes then take meeting notes"
        let consumed2 = "open notes"
        XCTAssertEqual(PreemptionPolicy.takeRemainder(full: full2, consumed: consumed2), "take meeting notes")

        // Trailing connector "and then"
        let fullAndThen = "open notes and then draft an email"
        let consumedAndThen = "open notes"
        XCTAssertEqual(PreemptionPolicy.takeRemainder(full: fullAndThen, consumed: consumedAndThen), "draft an email")

        // No remainder
        let full3 = "open notes"
        let consumed3 = "open notes"
        XCTAssertEqual(PreemptionPolicy.takeRemainder(full: full3, consumed: consumed3), "")

        // Empty remainder after connector
        let fullEmptyConn = "open notes and then"
        let consumedEmptyConn = "open notes"
        XCTAssertEqual(PreemptionPolicy.takeRemainder(full: fullEmptyConn, consumed: consumedEmptyConn), "")

        // Candidate remainder beginning mid-word must return nil
        let full4 = "open notesapp"
        let consumed4 = "open notes"
        XCTAssertNil(PreemptionPolicy.takeRemainder(full: full4, consumed: consumed4))

        // Normalized difference match (capitalization / punctuation) preserving exact remainder
        let full5 = "Open Notes, and write a memo."
        let consumed5 = "open notes"
        XCTAssertEqual(PreemptionPolicy.takeRemainder(full: full5, consumed: consumed5), "write a memo")

        // Email fixture
        let fullEmail = "open Mail and email user@example.com about review"
        let consumedEmail = "open mail"
        XCTAssertEqual(PreemptionPolicy.takeRemainder(full: fullEmail, consumed: consumedEmail), "email user@example.com about review")

        // URL fixture
        let fullUrl = "open Safari and go to https://example.com/api?v=2"
        let consumedUrl = "open safari"
        XCTAssertEqual(PreemptionPolicy.takeRemainder(full: fullUrl, consumed: consumedUrl), "go to https://example.com/api?v=2")

        // Phone number fixture
        let fullPhone = "open Messages and text +1-555-0199 hello"
        let consumedPhone = "open messages"
        XCTAssertEqual(PreemptionPolicy.takeRemainder(full: fullPhone, consumed: consumedPhone), "text +1-555-0199 hello")

        // Non-prefix transcript returns nil
        let fullNonPrefix = "please open Notes right now"
        let consumedNonPrefix = "open notes"
        XCTAssertNil(PreemptionPolicy.takeRemainder(full: fullNonPrefix, consumed: consumedNonPrefix))

        // Apostrophes & proper nouns
        let fullApos = "open Notes and check Sarah's schedule"
        let consumedApos = "open notes"
        XCTAssertEqual(PreemptionPolicy.takeRemainder(full: fullApos, consumed: consumedApos), "check Sarah's schedule")
    }
}
