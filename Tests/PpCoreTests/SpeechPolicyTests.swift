import XCTest
@testable import PpCore

final class PartialRouterTests: XCTestCase {

    func testWaitsForEnoughWords() {
        let router = PartialRouter(minimumTokens: 3)
        XCTAssertEqual(router.consider(partial: "open"), .wait)
        XCTAssertEqual(router.consider(partial: "open finder"), .wait)
    }

    func testPreroutesOnACompleteClause() {
        let router = PartialRouter(minimumTokens: 3)
        guard case .preroute(let clause) = router.consider(partial: "open finder and search") else {
            return XCTFail("expected a preroute")
        }
        XCTAssertEqual(clause, "open finder and search")
    }

    func testDoesNotPrerouteMidClause() {
        let router = PartialRouter(minimumTokens: 3)
        for partial in ["open finder and", "open finder then", "send the message to"] {
            XCTAssertEqual(router.consider(partial: partial), .wait, "'\(partial)' is still mid-sentence")
        }
    }

    func testPartialTranscriptsAreNeverActionableOnTheirOwn() {
        let router = PartialRouter(minimumTokens: 2)
        XCTAssertFalse(router.mayAct(partial: "send the message", clauseClosed: false))
        XCTAssertTrue(router.mayAct(partial: "send the message", clauseClosed: true))
        XCTAssertFalse(router.mayAct(partial: "   ", clauseClosed: true))
    }
}

final class PrerouteCacheTests: XCTestCase {

    func testCacheHitsWhenTheFinalTranscriptAgrees() {
        let cache = PrerouteCache()
        cache.store(clause: "open finder", value: "route:app")
        XCTAssertEqual(cache.take(ifMatching: "open finder and search notes"), "route:app")
    }

    func testCacheMissesWhenSpeechWasCorrected() {
        let cache = PrerouteCache()
        cache.store(clause: "open finder", value: "route:app")
        XCTAssertNil(cache.take(ifMatching: "open notes"), "a corrected transcript must invalidate the pre-computation")
    }

    func testClearAndEmptyBehaviour() {
        let cache = PrerouteCache()
        XCTAssertNil(cache.take(ifMatching: "anything"))
        cache.store(clause: "open", value: "v")
        cache.clear()
        XCTAssertNil(cache.take(ifMatching: "open finder"))
    }
}

final class AudioRetentionPolicyTests: XCTestCase {

    func testHoldToTalkAndWakeRetainEverythingElseDiscards() {
        XCTAssertEqual(AudioRetentionPolicy(wakePhrase: nil, holdToTalk: true).decide(heardWakePhrase: false), .retain)
        XCTAssertEqual(AudioRetentionPolicy(wakePhrase: "Hey pp", holdToTalk: false).decide(heardWakePhrase: true), .retain)
        XCTAssertEqual(AudioRetentionPolicy(wakePhrase: "Hey pp", holdToTalk: false).decide(heardWakePhrase: false), .discard)
        XCTAssertEqual(AudioRetentionPolicy(wakePhrase: nil, holdToTalk: false).decide(heardWakePhrase: false), .discard)
    }

    func testAudioIsNeverWrittenToDisk() {
        XCTAssertFalse(AudioRetentionPolicy(wakePhrase: "Hey pp", holdToTalk: true).writesToDisk)
    }
}

final class WakeWordControllerTests: XCTestCase {

    func testAudioBeforeTheWakePhraseIsNotRetained() {
        let controller = WakeWordController()
        controller.armForWake()
        XCTAssertEqual(controller.ingest(partial: "so anyway I was saying"), .buffered)
        XCTAssertTrue(controller.retainedWordsSnapshot.isEmpty, "nothing before the wake phrase may be kept")
    }

    func testWakePhraseWithACommandStartsCapture() {
        let controller = WakeWordController()
        controller.armForWake()
        XCTAssertEqual(controller.ingest(partial: "Hey pp open Finder"), .woke(command: "open Finder"))
        XCTAssertEqual(controller.currentState, .capturingCommand)
        XCTAssertEqual(controller.retainedWordsSnapshot, ["open", "finder"])
    }

    func testWakePhraseAloneArmsForTheCommand() {
        let controller = WakeWordController()
        controller.armForWake()
        XCTAssertEqual(controller.ingest(partial: "Hey pp"), .armed)
        XCTAssertEqual(controller.currentState, .capturingCommand)
    }

    func testKillSwitchStopsCaptureWithinOneBuffer() {
        let controller = WakeWordController()
        controller.armForWake()
        controller.kill()
        XCTAssertEqual(controller.currentState, .off)
        XCTAssertFalse(controller.isCapturing)
        XCTAssertEqual(controller.ingest(partial: "Hey pp open Finder"), .rejected)
        XCTAssertTrue(controller.retainedWordsSnapshot.isEmpty)
    }

    func testKillSwitchAlsoShedsAnInFlightCommandBuffer() {
        let controller = WakeWordController()
        controller.armForWake()
        _ = controller.ingest(partial: "Hey pp open Finder")
        XCTAssertFalse(controller.retainedWordsSnapshot.isEmpty)
        controller.kill()
        XCTAssertTrue(controller.retainedWordsSnapshot.isEmpty, "the kill switch must forget buffered audio")
    }

    func testRearmingAfterAKillDoesNotResurrectOldAudio() {
        let controller = WakeWordController()
        controller.armForWake()
        _ = controller.ingest(partial: "Hey pp open Finder")
        controller.kill()
        controller.rearmAfterKill()
        controller.armForWake()
        XCTAssertTrue(controller.retainedWordsSnapshot.isEmpty)
        XCTAssertEqual(controller.currentState, .listeningForWake)
    }

    func testFinishingACommandClearsTheBuffer() {
        let controller = WakeWordController()
        controller.armForWake()
        _ = controller.ingest(partial: "Hey pp open Finder")
        controller.finishCommand()
        XCTAssertTrue(controller.retainedWordsSnapshot.isEmpty)
        XCTAssertFalse(controller.writesToDisk)
    }
}

@MainActor
final class FakeSpeechProviderTests: XCTestCase {

    func testScriptedPartialsAndFinalFlowThroughTheProtocol() throws {
        let speech = FakeSpeechProvider()
        var received: [SpeechUpdate] = []
        speech.onUpdate = { received.append($0) }

        try speech.start(handsFree: true, wakePhrase: "Hey pp")
        XCTAssertTrue(speech.isListening)
        speech.emit(partial: "open")
        speech.emit(partial: "open finder")
        speech.emit(final: "open finder")
        XCTAssertFalse(speech.isListening)

        XCTAssertEqual(received.map(\.kind), [.partial, .partial, .final])
        XCTAssertEqual(received.last?.text, "open finder")
    }

    func testUpdatesBeforeStartAreDeliveredOnceListening() throws {
        let speech = FakeSpeechProvider()
        speech.emit(partial: "queued")
        var received: [SpeechUpdate] = []
        speech.onUpdate = { received.append($0) }
        try speech.start(handsFree: false, wakePhrase: nil)
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.text, "queued")
    }

    func testStopAndCancelBothEndListening() throws {
        let speech = FakeSpeechProvider()
        var failures: [String] = []
        speech.onUpdate = { if $0.kind == .failure { failures.append($0.text) } }
        try speech.start(handsFree: true, wakePhrase: nil)
        speech.stop()
        XCTAssertFalse(speech.isListening)
        try speech.start(handsFree: true, wakePhrase: nil)
        speech.emitFailure("recognition failed")
        speech.cancel()
        XCTAssertEqual(failures, ["recognition failed"])
        XCTAssertEqual(speech.stopCount, 2)
    }
}
