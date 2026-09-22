import XCTest
@testable import PpCore

final class PrivacyFilterTests: XCTestCase {

    func testForbiddenFieldCorpusIsRejected() {
        let forbidden = ["Password", "Confirm password", "CVV", "Card number", "SSN",
                         "One-time code", "2FA code", "API key", "Recovery code", "IBAN", "Expiry"]
        for label in forbidden {
            XCTAssertTrue(PrivacyFilter.isSensitiveField(label), "'\(label)' must be treated as sensitive")
        }
    }

    func testOrdinaryFieldsAreAllowed() {
        for label in ["Search", "Send", "Subject", "Attach", "Play", "Next track"] {
            XCTAssertFalse(PrivacyFilter.isSensitiveField(label), "'\(label)' should not be sensitive")
        }
    }

    func testCodesAndKeysAreRecognised() {
        XCTAssertTrue(PrivacyFilter.looksLikeSecret("483920"))
        XCTAssertTrue(PrivacyFilter.looksLikeSecret("4111 1111 1111 1111"))
        XCTAssertTrue(PrivacyFilter.looksLikeSecret("sk-live-abcdef123456"))
        XCTAssertTrue(PrivacyFilter.looksLikeSecret("ghp_abcdefghijklmnop"))
        XCTAssertFalse(PrivacyFilter.looksLikeSecret("open finder"))
        XCTAssertFalse(PrivacyFilter.looksLikeSecret("scroll down"))
    }

    func testStructuralFingerprintIgnoresContent() {
        let a = PrivacyFilter.structureFingerprint(roles: ["button", "textField", "link"])
        let b = PrivacyFilter.structureFingerprint(roles: ["link", "button", "textField"])
        XCTAssertEqual(a, b, "the same structure must fingerprint the same regardless of order")

        let different = PrivacyFilter.structureFingerprint(roles: ["button", "button", "link"])
        XCTAssertNotEqual(a, different)
    }

    func testEventWithSensitiveTargetIsDropped() {
        let event = InteractionEvent(at: Date(), clause: "fill in the password", app: "Safari",
                                     structureFingerprint: "abc", actionKind: "type_text",
                                     targetLabel: "Password field", succeeded: true, stepSignature: "sig")
        XCTAssertNil(PrivacyFilter.cleaned(event))
    }
}

final class EventLogTests: XCTestCase {

    private func event(_ clause: String = "open Finder", label: String? = "Finder", succeeded: Bool = true,
                       kind: String = "open_app") -> InteractionEvent {
        InteractionEvent(at: Date(), clause: clause, app: "Finder", structureFingerprint: "fp",
                         actionKind: kind, targetLabel: label, succeeded: succeeded, stepSignature: "sig")
    }

    func testRoundTrip() throws {
        let log = try EventLog.inMemory()
        try log.append(event())
        let recent = try log.recent(10)
        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(recent.first?.clause, "open Finder")
        XCTAssertEqual(try log.count(), 1)
    }

    func testFailedAttemptsAreNotRecorded() throws {
        let log = try EventLog.inMemory()
        try log.append(event(succeeded: false))
        XCTAssertEqual(try log.count(), 0)
    }

    func testSensitiveTargetsNeverReachTheDatabase() throws {
        let log = try EventLog.inMemory()
        try log.append(event("type the code", label: "Verification code", kind: "type_text"))
        try log.append(event("type my password", label: "Password", kind: "type_text"))
        XCTAssertEqual(try log.count(), 0)
    }

    func testDeleteAllLeavesNothingAndExportIsValid() throws {
        let log = try EventLog.inMemory()
        try log.append(event("open Finder"))
        try log.append(event("open Notes", label: "Notes"))
        let exported = try log.export()
        XCTAssertFalse(exported.isEmpty)
        let decoded = try PpJSON.decoder().decode([InteractionEvent].self, from: exported)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded, try log.recent(10), "an export must re-import to the exact same events")

        try log.deleteAll()
        XCTAssertEqual(try log.count(), 0)
        XCTAssertTrue(try log.recent(10).isEmpty)
    }

    func testRecentIsNewestFirst() throws {
        let log = try EventLog.inMemory()
        try log.append(InteractionEvent(at: Date(timeIntervalSince1970: 100), clause: "first", app: "A",
                                        structureFingerprint: "f", actionKind: "k", targetLabel: nil,
                                        succeeded: true, stepSignature: "s1"))
        try log.append(InteractionEvent(at: Date(timeIntervalSince1970: 200), clause: "second", app: "A",
                                        structureFingerprint: "f", actionKind: "k", targetLabel: nil,
                                        succeeded: true, stepSignature: "s2"))
        XCTAssertEqual(try log.recent(10).first?.clause, "second")
    }
}

final class MacroMinerTests: XCTestCase {

    private let steps = [PlanStep(kind: .openApp, target: "Finder"), PlanStep(kind: .typeText, target: "Search", text: "notes")]

    private func trace(_ clause: String, succeeded: Bool = true, steps: [PlanStep]? = nil) -> CommandTrace {
        CommandTrace(clause: clause, steps: steps ?? self.steps, succeeded: succeeded, app: "Finder")
    }

    func testMinesOnlyAfterEnoughSuccesses() {
        let two = MacroMiner.mine(traces: [trace("open finder and search notes"), trace("open finder and search notes")], minimumSupport: 3)
        XCTAssertTrue(two.isEmpty)

        let three = MacroMiner.mine(traces: Array(repeating: trace("open finder and search notes"), count: 3), minimumSupport: 3)
        XCTAssertEqual(three.count, 1)
        XCTAssertEqual(three.first?.successCount, 3)
    }

    func testFailuresNeverBecomeMacros() {
        let traces = [trace("open finder", succeeded: false), trace("open finder", succeeded: false), trace("open finder", succeeded: false)]
        XCTAssertTrue(MacroMiner.mine(traces: traces, minimumSupport: 3).isEmpty)
    }

    func testSignatureIsStableAndIgnoresTypedText() {
        let a = [PlanStep(kind: .openApp, target: "Finder"), PlanStep(kind: .typeText, target: "Search", text: "one")]
        let b = [PlanStep(kind: .openApp, target: "Finder"), PlanStep(kind: .typeText, target: "Search", text: "another")]
        XCTAssertEqual(MacroMiner.signature(for: a), MacroMiner.signature(for: b))
        XCTAssertNotEqual(MacroMiner.signature(for: a), MacroMiner.signature(for: [PlanStep(kind: .openApp, target: "Notes")]))
    }

    func testVariablesAreNamed() {
        XCTAssertEqual(MacroMiner.variables(for: steps), ["text"])
    }

    func testTriggerMatchingUsesSignificantTokens() {
        let macro = Macro(id: "x", name: "open finder and search notes", triggerPattern: "open finder and search notes",
                          triggerTokens: MacroMiner.significantTokens("open finder and search notes"),
                          app: "Finder", preconditions: [], steps: steps, variables: ["text"],
                          verification: "none", successCount: 3, lastUsedAt: Date())
        XCTAssertGreaterThan(macro.match("open finder and search my notes"), 0.6)
        XCTAssertLessThan(macro.match("book a flight to Delhi"), 0.3)
    }
}

final class MacroLibraryTests: XCTestCase {

    private func macro(_ id: String, clause: String, enabled: Bool = true, app: String? = nil) -> Macro {
        Macro(id: id, name: clause, triggerPattern: clause, triggerTokens: MacroMiner.significantTokens(clause),
              app: app, preconditions: [], steps: [PlanStep(kind: .openApp, target: "Finder")],
              variables: [], verification: "none", successCount: 3, lastUsedAt: Date(), enabled: enabled)
    }

    func testRetrievesTheBestMatch() {
        let library = MacroLibrary(macros: [macro("a", clause: "open finder and search notes"),
                                            macro("b", clause: "book a flight to delhi")])
        XCTAssertEqual(library.bestMatch(for: "open finder and search my notes", app: nil)?.id, "a")
        XCTAssertNil(library.bestMatch(for: "something entirely unrelated", app: nil))
    }

    func testDisabledMacrosAreNotRetrieved() {
        let library = MacroLibrary(macros: [macro("a", clause: "open finder and search notes", enabled: false)])
        XCTAssertNil(library.bestMatch(for: "open finder and search notes", app: nil))
    }

    func testRetrievalStaysFarUnderTwentyMilliseconds() {
        let many = (0..<200).map { macro("m\($0)", clause: "open finder and search notes number \($0)") }
        let library = MacroLibrary(macros: many)
        let start = DispatchTime.now()
        for _ in 0..<50 { _ = library.bestMatch(for: "open finder and search my notes", app: nil) }
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000 / 50
        XCTAssertLessThan(elapsedMs, 20, "macro retrieval must not be on the slow path")
    }
}

final class RankingFeatureTests: XCTestCase {

    private func event(label: String, app: String = "Finder", kind: String = "click", at: Date = Date()) -> InteractionEvent {
        InteractionEvent(at: at, clause: "do the thing", app: app, structureFingerprint: "fp",
                         actionKind: kind, targetLabel: label, succeeded: true, stepSignature: "sig")
    }

    func testLearningRequiresRepeatedSuccess() {
        var features = RankingFeatures.learn(from: [event(label: "Save"), event(label: "Save")])
        XCTAssertTrue(features.successfulTargets.isEmpty, "two uses is not yet a habit")

        features = RankingFeatures.learn(from: Array(repeating: event(label: "Save"), count: 4))
        XCTAssertEqual(features.successfulTargets["Finder|save"], 4)
        XCTAssertGreaterThan(features.priorBoost(app: "Finder", labels: ["Save"])["save"] ?? 0, 0)
    }

    func testPriorsReorderCandidatesWithoutDroppingAny() {
        let model = RankingModel(features: RankingFeatures(successfulTargets: ["Zen|open link": 5]), minimumUses: 3)
        let candidates = [
            UICandidate(id: "1", label: "Close", detail: "", role: .button),
            UICandidate(id: "2", label: "Open link", detail: "", role: .button)
        ]
        let ranked = model.rank(candidates, command: "open", app: "Zen")
        XCTAssertEqual(ranked.first?.id, "2")
        XCTAssertEqual(Set(ranked.map(\.id)), Set(["1", "2"]), "ranking must never drop a candidate")
    }

    func testLearnedPriorsCannotBypassTheSafetyCritic() {
        // The habit is strong, and the top candidate is still gated.
        let model = RankingModel(features: RankingFeatures(successfulTargets: ["Mail|send": 40]), minimumUses: 3)
        let candidates = [UICandidate(id: "1", label: "Discard", detail: "", role: .button),
                          UICandidate(id: "2", label: "Send", detail: "Send the message", role: .button)]
        let ranked = model.rank(candidates, command: "send the message", app: "Mail")
        XCTAssertEqual(ranked.first?.label, "Send", "the prior should be able to surface it")

        let verdict = SafetyCritic.evaluate(actionLabel: ranked[0].label, actionDetail: ranked[0].detail,
                                            command: "send the message", confidence: 1.0)
        XCTAssertTrue(verdict.isBlocked, "a learned habit must never authorise an outward send")
    }

    func testAliasesAreAddressedToTheRightApp() {
        let features = RankingFeatures(appAliases: ["mail": "Spark"])
        XCTAssertEqual(features.appAliases["mail"], "Spark")
        XCTAssertNil(features.priorBoost(app: "Finder", labels: ["Send"])["send"])
    }
}

final class PersonalizationStoreTests: XCTestCase {

    private func makeStore() -> (PersonalizationStore, MacroLibrary, RankingModel) {
        let macros = MacroLibrary()
        let ranking = RankingModel(features: RankingFeatures(appAliases: ["mail": "Spark"],
                                                             successfulTargets: ["Zen|open link": 5],
                                                             frequentContacts: ["Diya": 4]),
                                   minimumUses: 1)
        return (PersonalizationStore(macros: macros, ranking: ranking), macros, ranking)
    }

    func testEverythingLearnedIsVisible() {
        let (store, _, _) = makeStore()
        let kinds = Set(store.items().map(\.kind))
        XCTAssertTrue(kinds.contains(.alias))
        XCTAssertTrue(kinds.contains(.contact))
        XCTAssertTrue(kinds.contains(.prior))
    }

    func testExportDeleteImportRoundTrip() throws {
        let (store, _, _) = makeStore()
        let before = store.items()
        let bundle = try store.export()

        store.deleteEverything()
        XCTAssertTrue(store.items().isEmpty)

        try store.importBundle(bundle)
        XCTAssertEqual(store.items().count, before.count)
    }

    func testRenameAndDeleteTargetOneItem() throws {
        let (store, _, _) = makeStore()
        let alias = try XCTUnwrap(store.items().first { $0.kind == .alias })
        try store.rename(id: alias.id, to: "Work email")
        XCTAssertEqual(store.items().first { $0.id == alias.id }?.title, "Work email")

        try store.delete(id: alias.id)
        XCTAssertFalse(store.items().contains { $0.id == alias.id })
        XCTAssertThrowsError(try store.delete(id: alias.id))
    }

    func testDisablingAMacroActuallyStopsItBeingUsed() {
        let macros = MacroLibrary()
        let ranking = RankingModel()
        let store = PersonalizationStore(macros: macros, ranking: ranking)
        let macro = Macro(id: "abc123abc123abcd", name: "open finder and search notes",
                          triggerPattern: "open finder and search notes",
                          triggerTokens: MacroMiner.significantTokens("open finder and search notes"),
                          app: nil, preconditions: [], steps: [PlanStep(kind: .openApp, target: "Finder")],
                          variables: [], verification: "none", successCount: 5, lastUsedAt: Date())
        macros.insert(macro)
        XCTAssertNotNil(macros.bestMatch(for: "open finder and search notes", app: nil))

        try? store.setEnabled(id: macro.id, enabled: false)
        XCTAssertNil(macros.bestMatch(for: "open finder and search notes", app: nil),
                     "disabling a macro must stop it being retrieved, not just dim it in the list")
    }

    func testEmptyRenameIsRefused() {
        let (store, _, _) = makeStore()
        let item = store.items()[0]
        XCTAssertThrowsError(try store.rename(id: item.id, to: "   ")) { error in
            XCTAssertEqual(error as? PersonalizationError, .emptyTitle)
        }
    }
}

/// The one JSON convention itself, tested directly. Every export promise in the app rests
/// on this file: "export produces a complete, importable bundle" is false if a value comes
/// back different.
final class PpJSONTests: XCTestCase {

    func testWallClockDatesSurviveAnEncodeDecodeCycleExactly() throws {
        // Dates from the clock are the hard case: they carry a full-precision reference-date
        // double, and re-encoding them as seconds-since-1970 re-rounds against a ~9.8e8
        // offset, so about 40% of them came back one ULP different. Many samples, because
        // one sample only catches a regression ~40% of the time.
        let dates = (0..<200).map { _ in Date() }
        let data = try PpJSON.encoder().encode(dates)
        XCTAssertEqual(try PpJSON.decoder().decode([Date].self, from: data), dates)
    }

    func testEncodingIsStableAcrossRepeatedCycles() throws {
        var dates = [Date()]
        for _ in 0..<5 {
            let data = try PpJSON.encoder().encode(dates)
            let decoded = try PpJSON.decoder().decode([Date].self, from: data)
            XCTAssertEqual(decoded, dates, "a stored value must not drift on every save")
            dates = decoded
        }
    }

    func testDistantDatesAndEpochEdgesSurvive() throws {
        let dates = [Date(timeIntervalSince1970: 0), Date(timeIntervalSinceReferenceDate: 0),
                     Date(timeIntervalSince1970: -1), Date(timeIntervalSince1970: 4_102_444_800),
                     Date.distantFuture, Date.distantPast]
        let data = try PpJSON.encoder().encode(dates)
        XCTAssertEqual(try PpJSON.decoder().decode([Date].self, from: data), dates)
    }
}

/// The learning rules, tested where they live rather than through the UI: what gets
/// remembered, what is refused, and what repetition is allowed to turn into a macro.
final class LearningRecorderTests: XCTestCase {

    private func makeRecorder(minimumSupport: Int = 3) throws -> (LearningRecorder, MacroLibrary, RankingModel, EventLog) {
        let log = try EventLog.inMemory()
        let macros = MacroLibrary()
        let ranking = RankingModel()
        let recorder = LearningRecorder(history: log, macros: macros, ranking: ranking, minimumSupport: minimumSupport)
        return (recorder, macros, ranking, log)
    }

    private func openFinder(_ recorder: LearningRecorder, app: String = "Finder") {
        recorder.begin(clause: "open Finder", app: app)
        recorder.record(step: PlanStep(kind: .openApp, target: "Finder"), label: "Open Finder",
                        kind: "open_app", signature: "finder", roles: ["AXButton"], succeeded: true)
        recorder.finish(succeeded: true)
    }

    func testRepeatedCommandsBecomeMacros() throws {
        let (recorder, macros, _, log) = try makeRecorder()
        for _ in 0..<2 { openFinder(recorder) }
        XCTAssertTrue(macros.all().isEmpty, "two repetitions is a coincidence, not a habit")
        openFinder(recorder)
        XCTAssertEqual(macros.all().count, 1)
        XCTAssertEqual(try log.count(), 3, "every successful step is still in the history")

        let recalled = recorder.macro(for: "open Finder", app: "Finder")
        XCTAssertEqual(recalled?.steps.first?.kind, .openApp)
        XCTAssertEqual(recalled?.steps.first?.target, "Finder")
    }

    func testAMacroIsRetrievedFromASpokenVariation() throws {
        let (recorder, _, _, _) = try makeRecorder()
        for _ in 0..<3 { openFinder(recorder) }
        XCTAssertNotNil(recorder.macro(for: "open the Finder app", app: "Finder"))
        XCTAssertNil(recorder.macro(for: "delete every note in the folder", app: "Finder"),
                     "an unrelated command must not match a macro")
    }

    func testFailedCommandsTeachNothing() throws {
        let (recorder, macros, _, log) = try makeRecorder(minimumSupport: 1)
        for _ in 0..<3 {
            recorder.begin(clause: "open Finder", app: "Finder")
            recorder.record(step: PlanStep(kind: .openApp, target: "Finder"), label: "Open Finder",
                            kind: "open_app", signature: "finder", roles: ["AXButton"], succeeded: false)
            recorder.finish(succeeded: false)
        }
        XCTAssertTrue(macros.all().isEmpty)
        XCTAssertEqual(try log.count(), 0)
        XCTAssertTrue(recorder.recordedTraces.isEmpty, "a failed command is not a trace")
    }

    func testASecretNeverReachesTheLogOrAMacro() throws {
        let (recorder, macros, _, log) = try makeRecorder(minimumSupport: 1)
        for _ in 0..<3 {
            recorder.begin(clause: "enter the code", app: "Safari")
            recorder.record(step: PlanStep(kind: .typeText, target: "Code field: 483920"),
                            label: "Code field: 483920", kind: "type_text",
                            signature: "code", roles: ["AXTextField"], succeeded: true)
            recorder.finish(succeeded: true)
        }
        XCTAssertEqual(try log.count(), 0, "a one-time code must never be written down")
        XCTAssertTrue(macros.all().isEmpty)
    }

    func testRecallOnlyReordersAndNeverGrantsPermission() throws {
        let (recorder, macros, _, _) = try makeRecorder()
        for _ in 0..<3 { openFinder(recorder) }
        let recalled = try XCTUnwrap(recorder.macro(for: "open Finder", app: "Finder"))
        // The macro carries steps, and the safety critic still sees every one of them.
        XCTAssertEqual(SafetyCritic.evaluate(step: recalled.steps[0], goal: "open Finder"), .safe)
        let send = PlanStep(kind: .typeText, target: "Message", text: "send it now")
        XCTAssertTrue(SafetyCritic.evaluate(step: send, goal: "send it").isBlocked,
                      "a remembered habit must not turn an outward action into an allowed one")
        XCTAssertFalse(macros.all().isEmpty)
    }

    func testTracesSurviveASaveAndReloadAndStayCapped() throws {
        let (recorder, _, _, _) = try makeRecorder(minimumSupport: 2)
        openFinder(recorder)
        let exported = try PpJSON.encoder().encode(recorder.exportTraces())
        let restored = try PpJSON.decoder().decode([CommandTrace].self, from: exported)
        XCTAssertEqual(restored, recorder.recordedTraces)

        let (fresh, macros, _, _) = try makeRecorder(minimumSupport: 2)
        fresh.replaceTraces(restored)
        openFinder(fresh)
        XCTAssertEqual(macros.all().count, 1, "two runs, one of them before a restart, still make a macro")
    }

    func testMiningNeverReEnablesAMacroTheUserTurnedOff() throws {
        let (recorder, macros, _, _) = try makeRecorder()
        for _ in 0..<3 { openFinder(recorder) }
        let macro = try XCTUnwrap(macros.all().first)
        var disabled = macro
        disabled.enabled = false
        macros.insert(disabled)

        openFinder(recorder)
        XCTAssertEqual(macros.all().first?.enabled, false, "mining adds, it does not re-enable")
    }
}
