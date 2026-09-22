import XCTest
@testable import PpCore

/// Shortlisting, question construction, sessions, verification and the planner seam —
/// the layers that make the coordinator runnable with no UI, no audio and no weights.
final class ShortlisterTests: XCTestCase {

    private func screen() -> [UICandidate] {
        [
            UICandidate(id: "1", label: "Zen", detail: "Application window", role: .other, depth: 0),
            UICandidate(id: "2", label: "Search", detail: "Search input", role: .textField, depth: 3),
            UICandidate(id: "3", label: "Bookmarks", detail: "Menu", role: .menuItem, depth: 4),
            UICandidate(id: "4", label: "Send", detail: "Send the draft email", role: .button, depth: 5),
            UICandidate(id: "5", label: "", detail: "unnamed container", role: .other, depth: 6),
            UICandidate(id: "6", label: "Scroll bar", detail: "Vertical scroller", role: .slider, depth: 7)
        ]
    }

    func testMentionedControlRanksFirst() {
        let ranked = Shortlister.rank(screen(), command: "send the draft")
        XCTAssertEqual(ranked.first?.id, "4")
    }

    func testUnnamedElementsAreDropped() {
        let ranked = Shortlister.rank(screen(), command: "click anything")
        XCTAssertFalse(ranked.contains { $0.id == "5" })
        XCTAssertEqual(ranked.count, 5)
    }

    func testRankingIsDeterministic() {
        let first = Shortlister.rank(screen(), command: "search")
        let second = Shortlister.rank(screen(), command: "search")
        XCTAssertEqual(first, second)
    }

    func testTiesBreakOnIdentifierSoTheSameScreenRanksTheSameWay() {
        let candidates = [
            UICandidate(id: "b", label: "Open", detail: "", role: .button),
            UICandidate(id: "a", label: "Open", detail: "", role: .button)
        ]
        XCTAssertEqual(Shortlister.rank(candidates, command: "open").map(\.id), ["a", "b"])
    }

    func testLimitIsHonouredAndReported() {
        let many = (0..<40).map { UICandidate(id: "\($0)", label: "Item \($0)", detail: "", role: .button) }
        let ranked = Shortlister.rank(many, command: "item 7")
        XCTAssertEqual(ranked.count, Shortlister.defaultLimit)
        XCTAssertTrue(Shortlister.didTruncate(many))
        XCTAssertTrue(ranked.contains { $0.id == "7" }, "the mentioned item must survive truncation")
    }

    func testLearnedPriorReordersButDoesNotInventCandidates() {
        let candidates = [
            UICandidate(id: "1", label: "Save", detail: "", role: .button),
            UICandidate(id: "2", label: "Save as", detail: "", role: .button)
        ]
        let plain = Shortlister.rank(candidates, command: "save")
        let biased = Shortlister.rank(candidates, command: "save", options: Shortlister.Options(priorBoost: ["save as": 5.0]))
        XCTAssertEqual(plain.first?.id, "1")
        XCTAssertEqual(biased.first?.id, "2")
        XCTAssertEqual(Set(biased.map(\.id)), Set(["1", "2"]))
    }
}

final class QuestionBuilderTests: XCTestCase {

    func testYesNoQuestionsUseFalseThenTrueSoProbabilityOneIsYes() {
        for question in [
            QuestionBuilder.safety(stepSummary: "Click Send", goal: "send it"),
            QuestionBuilder.completion(goal: "open Finder", lastAction: "Open Finder"),
            QuestionBuilder.alreadyDone(step: PlanStep(kind: .openApp, target: "Finder"), goal: "open finder")
        ] {
            XCTAssertEqual(question.type, "noul")
            XCTAssertEqual(question.options.count, 2)
            XCTAssertTrue(question.options[0].hasPrefix("false:"))
            XCTAssertTrue(question.options[1].hasPrefix("true:"))
            XCTAssertEqual(question.optionIDs, ["false", "true"])
            XCTAssertEqual(QuestionBuilder.yesProbability([0.2, 0.8]), 0.8, accuracy: 1e-6)
        }
    }

    func testTargetQuestionEndsWithNone() {
        let candidates = [Candidate(id: "a", label: "Send", detail: "button")]
        let question = QuestionBuilder.target(goal: "send it", step: PlanStep(kind: .click, target: "Send"), candidates: candidates)
        XCTAssertEqual(question.optionIDs, ["a", "none"])
        XCTAssertEqual(question.id(forIndex: 1), "none")
    }

    func testRouterCoversEveryRouteAndIncludesPluginsOnlyWhenPresent() {
        let without = QuestionBuilder.router(goal: "turn the volume up")
        XCTAssertEqual(without.optionIDs, ["app", "browser", "system", "conversation"])
        let with = QuestionBuilder.router(goal: "post to Slack", availablePlugins: ["Slack"])
        XCTAssertTrue(with.optionIDs.contains("plugin"))
        XCTAssertEqual(with.options.count, with.optionIDs.count)
    }

    func testOptionIndexMapsBackToAnIdentifier() {
        let question = QuestionBuilder.actionKind(goal: "scroll down")
        for index in question.options.indices {
            XCTAssertNotNil(question.id(forIndex: index))
        }
        XCTAssertNil(question.id(forIndex: 99))
    }
}

final class SessionStoreTests: XCTestCase {

    func testChainedClausesResolveTheLinkAndThenThePerson() {
        let session = SessionStore()
        session.record(clause: "open Zen", action: "Open Zen", app: "Zen")
        session.record(clause: "find the launch notes", action: "Type launch notes", app: "Zen", url: "https://zen.example/launch")

        // Third clause: the link resolves from history, and Diya is newly named.
        XCTAssertEqual(session.contextNote(for: "send the link to Diya"),
                       "'the link' refers to https://zen.example/launch")
        XCTAssertEqual(session.snapshot().lastPerson, "Diya")

        // Fourth clause: "them" now means the person named a moment ago.
        XCTAssertEqual(session.contextNote(for: "also add them a note"), "'them' refers to Diya")
    }

    func testPronounFallsBackToTheTargetThenTheApp() {
        let session = SessionStore()
        session.record(clause: "open Finder", app: "Finder")
        XCTAssertEqual(session.resolve(reference: "close it"), "Finder")
        session.record(clause: "click the Get Info button", target: "Get Info")
        XCTAssertEqual(session.resolve(reference: "do that again"), "Get Info")
    }

    func testNoReferentMeansNoNote() {
        let session = SessionStore()
        XCTAssertNil(session.contextNote(for: "open Finder"))
        XCTAssertNil(session.resolve(reference: "open Finder"))
    }

    func testSentenceInitialWordsAreNotTreatedAsNames() {
        XCTAssertNil(SessionStore.person(in: "Then open Finder"))
        XCTAssertNil(SessionStore.person(in: "open Finder to look around"))
        XCTAssertEqual(SessionStore.person(in: "send the link to Diya"), "Diya")
    }

    func testResetClearsTheSession() {
        let session = SessionStore()
        session.record(clause: "open Zen", app: "Zen")
        session.reset()
        XCTAssertNil(session.snapshot().lastApp)
        XCTAssertTrue(session.snapshot().clauses.isEmpty)
    }
}

final class VerifierTests: XCTestCase {

    private func snapshot(app: String = "Finder", title: String = "Home", labels: [String] = ["Open"], focused: String? = nil) -> ObservationSnapshot {
        ObservationSnapshot(app: app, windowTitle: title, labels: labels, focusedValue: focused,
                            fingerprint: ObservationSnapshot.fingerprint(app: app, windowTitle: title, labels: labels))
    }

    func testExpectedEffectPerStepKind() {
        XCTAssertEqual(ExpectedEffect.expected(for: PlanStep(kind: .openApp, target: "Finder")).kind, .appFrontmost)
        XCTAssertEqual(ExpectedEffect.expected(for: PlanStep(kind: .typeText, target: nil, text: "hello")).kind, .fieldContains)
        XCTAssertEqual(ExpectedEffect.expected(for: PlanStep(kind: .scroll, target: "down")).kind, .contentMoved)
        XCTAssertEqual(ExpectedEffect.expected(for: PlanStep(kind: .focusInput, target: "search")).kind, .none)
    }

    func testDoneWhenTheExpectedAppIsFrontmost() {
        let outcome = Verifier.verify(ExpectedEffect(kind: .appFrontmost, value: "Finder"),
                                      before: snapshot(app: "Zen"), after: snapshot(app: "Finder"), attempt: 0)
        XCTAssertEqual(outcome, .done)
    }

    func testNothingChangedRetriesThenReplansWithinBudget() {
        let expected = ExpectedEffect(kind: .windowTitleContains, value: "Launch")
        let before = snapshot(title: "Home")
        let same = snapshot(title: "Home")
        XCTAssertEqual(Verifier.verify(expected, before: before, after: same, attempt: 0), .retry(reason: "nothing changed on screen"))
        XCTAssertEqual(Verifier.verify(expected, before: before, after: same, attempt: 2), .retry(reason: "nothing changed on screen"))
        guard case .replan = Verifier.verify(expected, before: before, after: same, attempt: 3) else {
            return XCTFail("the retry budget must end in a replan, not another blind repeat")
        }
    }

    func testUnexpectedChangeReplansInsteadOfRepeating() {
        let expected = ExpectedEffect(kind: .windowTitleContains, value: "Launch")
        let outcome = Verifier.verify(expected, before: snapshot(title: "Home"), after: snapshot(title: "Settings"), attempt: 0)
        guard case .replan = outcome else { return XCTFail("expected replan, got \(outcome)") }
    }

    func testUnobservableEffectIsNotTreatedAsFailure() {
        let before = snapshot()
        XCTAssertEqual(Verifier.verify(ExpectedEffect(kind: .none), before: before, after: before, attempt: 0), .done)
    }

    func testQuitAppVerifiesByDisappearance() {
        let expected = ExpectedEffect(kind: .labelDisappeared, value: "Notes")
        XCTAssertEqual(Verifier.verify(expected, before: snapshot(labels: ["Notes"]), after: snapshot(labels: ["Finder"]), attempt: 0), .done)
    }
}

final class EffectLedgerTests: XCTestCase {

    func testOutwardClickIsRecordedAsIrreversible() {
        let ledger = EffectLedger()
        ledger.record(PlanStep(kind: .click, target: "Send"), previousApp: "Zen")
        XCTAssertEqual(ledger.irreversible.count, 1)
        XCTAssertTrue(ledger.undoPlan().first?.contains("Cannot undo") == true)
    }

    func testTypingAndAppSwitchingAreReversible() {
        let ledger = EffectLedger()
        ledger.record(PlanStep(kind: .typeText, target: "Subject", text: "hi"))
        ledger.record(PlanStep(kind: .openApp, target: "Finder"), previousApp: "Zen")
        XCTAssertTrue(ledger.irreversible.isEmpty)
        XCTAssertEqual(ledger.undoPlan().first, "Return to Zen.")
    }

    func testLedgerRecordsNothingSecret() {
        let ledger = EffectLedger()
        ledger.record(PlanStep(kind: .typeText, target: "Password", text: "hunter2"))
        // The ledger keeps the step summary, never the typed secret.
        let description = String(describing: ledger.entries)
        XCTAssertFalse(description.contains("hunter2"), "typed secrets must not be retained in the ledger")
    }
}

final class PlannerSeamTests: XCTestCase {

    func testOnlyLoopbackEndpointsAreAccepted() throws {
        XCTAssertTrue(PlannerEndpointPolicy.isLoopback(URL(string: "http://127.0.0.1:8080/v1/chat/completions")!))
        XCTAssertTrue(PlannerEndpointPolicy.isLoopback(URL(string: "http://localhost:11434/v1/chat/completions")!))
        XCTAssertTrue(PlannerEndpointPolicy.isLoopback(URL(string: "http://[::1]:8080/v1")!))
        XCTAssertFalse(PlannerEndpointPolicy.isLoopback(URL(string: "https://api.example.com/v1")!))
        XCTAssertFalse(PlannerEndpointPolicy.isLoopback(URL(string: "http://192.168.1.10:8080/v1")!))
        XCTAssertFalse(PlannerEndpointPolicy.isLoopback(URL(string: "http://127.0.0.1.evil.com/v1")!))
    }

    func testLocalPlannerRefusesARemoteEndpoint() {
        XCTAssertThrowsError(try LocalServerPlanner(endpoint: URL(string: "https://api.example.com/v1")!)) { error in
            guard let policy = error as? PlannerEndpointPolicy.PolicyError,
                  policy.message.contains("not on this machine") else {
                return XCTFail("expected a loopback refusal, got \(error)")
            }
        }
        XCTAssertNoThrow(try LocalServerPlanner(endpoint: URL(string: "http://127.0.0.1:8080/v1")!))
    }

    func testGrammarPlannerNeedsNoNetworkAndProducesSteps() async throws {
        let planner = GrammarPlannerProvider()
        XCTAssertFalse(planner.requiresNetwork)
        let steps = try await planner.plan(utterance: "open Finder", frontApp: "Zen", runningApps: [])
        XCTAssertEqual(steps.first?.kind, .openApp)
    }

    func testRecordedPlannerReplaysWithoutAModel() async throws {
        let planner = RecordedPlanner(table: ["open finder": [PlanStep(kind: .openApp, target: "Finder")]])
        let steps = try await planner.plan(utterance: "Open Finder", frontApp: "Zen", runningApps: [])
        XCTAssertEqual(steps, [PlanStep(kind: .openApp, target: "Finder")])
        await XCTAssertThrowsErrorAsync(try await planner.plan(utterance: "unknown", frontApp: "", runningApps: []))
    }

    func testTestClockAdvances() {
        var clock = TestClock()
        let start = clock.now
        clock.advance(61)
        XCTAssertEqual(clock.now.timeIntervalSince(start), 61, accuracy: 0.001)
    }
}

/// Small async helper so a throwing call can be asserted in an async test.
func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath, line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {
        // expected
    }
}
