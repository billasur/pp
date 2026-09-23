import AppKit
import Carbon

@main
struct DesktopChecks {
    @MainActor static func main() async throws {
        let name = "local.pp.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        precondition(KeyboardShortcut.load(defaults: defaults) == .defaultShortcut)
        func event(_ code: UInt16, _ flags: NSEvent.ModifierFlags, _ text: String) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
        }
        let shortcut = KeyboardShortcut(event: event(40, [.command, .shift], "k"))
        precondition(shortcut.keyCode == 40)
        precondition(shortcut.modifiers == UInt32(cmdKey | shiftKey))
        precondition(shortcut.label == "⇧⌘K")
        shortcut.save(defaults: defaults)
        precondition(KeyboardShortcut.load(defaults: defaults) == shortcut)
        defaults.set(Data("invalid".utf8), forKey: "VoiceShortcut")
        precondition(KeyboardShortcut.load(defaults: defaults) == .defaultShortcut)
        precondition(KeyboardShortcut(event: event(122, [], "")).label == "F1")
        precondition(KeyboardShortcut(event: event(49, [.control, .option], " ")) == .defaultShortcut)
        precondition(KeyboardShortcut(event: event(123, [.command], "")).label == "⌘←")
        let speech = SpeechInput()
        var delivered = false
        speech.onFinal = { _ in delivered = true }
        speech.finish()
        speech.cancel()
        speech.finish()
        precondition(!speech.isListening && !delivered)
        precondition(WakePhrase.command(in: "Hey Jev", after: "Hey Jev") == "")
        precondition(WakePhrase.command(in: "HEY, JEV! Open Finder", after: "Hey Jev") == "Open Finder")
        precondition(WakePhrase.command(in: "Hey Jev, type Hello, world!", after: "Hey Jev") == "type Hello, world!")
        precondition(WakePhrase.command(in: "Hey Jev, type \"Hello!\"", after: "Hey Jev") == "type \"Hello!\"")
        precondition(WakePhrase.command(in: "Hey Jevons open Finder", after: "Hey Jev") == nil)
        precondition(WakePhrase.command(in: "Someone said Hey Jev", after: "Hey Jev") == nil)
        precondition(WakePhrase.command(in: "Open Finder", after: "Hey Jev") == nil)
        precondition(WakePhrase.command(in: "Hey", after: "Hey Jev") == nil)
        precondition(WakePhrase.command(in: "Hey Jev", after: "") == nil)
        precondition(WakePhrase.command(in: "Hey Jeff", after: "Hey Jev") == "")
        precondition(WakePhrase.command(in: "Hey Jeff, open Finder", after: "Hey Jev") == "open Finder")
        precondition(WakePhrase.command(in: "Hey Jeff", after: "Hey Sam") == nil)
        precondition(WakePhrase.command(in: "Hey pp", after: "Hey pp") == "")
        precondition(WakePhrase.command(in: "HEY, PP! Open Finder", after: "Hey pp") == "Open Finder")
        precondition(WakePhrase.command(in: "Hey pp, type Hello, world!", after: "Hey pp") == "type Hello, world!")
        precondition(WakePhrase.command(in: "Hey pee pee, open Finder", after: "Hey pp") == "open Finder")
        precondition(WakePhrase.command(in: "ey pp, open Finder", after: "Hey pp") == "open Finder")
        precondition(WakePhrase.command(in: "pp, open Finder", after: "Hey pp") == "open Finder")
        precondition(DismissalPhrase.match("stop") == .cancel)
        precondition(DismissalPhrase.match("cancel") == .cancel)
        precondition(DismissalPhrase.match("thank you") == .dismiss)
        precondition(DismissalPhrase.match("stop the music") == nil)
        precondition(DismissalPhrase.match("cancel my subscription") == nil)
        precondition(DismissalPhrase.match("thank you for the notes") == nil)
        // The fast path behind "open Notes" finishing before the sentence ends: the words
        // must name exactly one target, and the target must resolve without a screen read.
        precondition(DirectIntentParser.parse("open finder") == .openApp(name: "finder"))
        precondition(DirectIntentParser.parse("open finder and search for reports") == .none)
        let noSpeech = NSError(domain: "kAFAssistantErrorDomain", code: 1110)
        var restarts = 0
        var failures = 0
        speech.onIdle = { restarts += 1 }
        speech.onFailure = { _ in failures += 1 }
        for _ in 0..<2 {
            speech.handleRecognitionError(noSpeech, handsFree: true)
            try await Task.sleep(nanoseconds: 450_000_000)
        }
        precondition(restarts == 2 && failures == 0 && !delivered)
        speech.handleRecognitionError(noSpeech, handsFree: true)
        speech.cancel()
        try await Task.sleep(nanoseconds: 450_000_000)
        precondition(restarts == 2, "Stop must cancel queued recovery")
        speech.handleRecognitionError(noSpeech, handsFree: false)
        precondition(failures == 1, "Hold-to-talk must still report silence")
        speech.handleRecognitionError(NSError(domain: "Other", code: 1110), handsFree: true)
        precondition(failures == 2)
        speech.handleRecognitionError(NSError(domain: "kAFAssistantErrorDomain", code: 1101), handsFree: true)
        precondition(failures == 3)
        speech.transcript = "unfinished command"
        speech.handleRecognitionError(noSpeech, handsFree: true)
        // Preemption policy checks: stability and mid-word safe remainder
        var policy = PreemptionPolicy()
        precondition(policy.observe(PartialObservation(clause: "open not", isFinal: false, monotonicTime: 0.0)) == .wait)
        precondition(policy.observe(PartialObservation(clause: "open notes", isFinal: false, monotonicTime: 0.1)) == .wait) // 1st stable
        let decision = policy.observe(PartialObservation(clause: "open notes", isFinal: false, monotonicTime: 0.2)) // 2nd stable
        precondition(decision == .preempt(step: PlanStep(kind: .openApp, target: "notes"), clause: "open notes"))
        // Scripted partial stream proving cooldown:
        let obsCooldown1 = PartialObservation(clause: "open safari", isFinal: false, monotonicTime: 0.5) // inside 1.5s cooldown
        precondition(policy.observe(obsCooldown1) == .wait, "Cooldown must block repeated launch inside 1.5s")
        let obsCooldown2 = PartialObservation(clause: "open safari", isFinal: false, monotonicTime: 2.0) // after 1.5s cooldown
        precondition(policy.observe(obsCooldown2) == .supersede(step: PlanStep(kind: .openApp, target: "safari"), clause: "open safari"), "Supersede allowed after cooldown")

        precondition(PreemptionPolicy.takeRemainder(full: "open notes and write down hello", consumed: "open notes") == "write down hello")
        precondition(PreemptionPolicy.takeRemainder(full: "open notes and write Sumit's number", consumed: "open notes") == "write Sumit's number")
        precondition(PreemptionPolicy.takeRemainder(full: "open notesapp", consumed: "open notes") == nil) // Mid-word safety returns nil

        // Scripted WakeSession partial stream: wake, pause, three clauses, dismissal -> 3 executions, 1 close
        var multiSession = WakeSession(initialPhase: .wakeListening)
        var executedClauses: [String] = []
        var sessionClosed = false

        let wakeOutcome = multiSession.ingest(partial: "hey pp", at: 1.0)
        precondition(wakeOutcome == .woke(command: ""))
        precondition(multiSession.clauseCompleted("hey pp", at: 1.2) == .none)
        precondition(multiSession.phase == .session)

        _ = multiSession.ingest(partial: "open zen", at: 3.0)
        if case .execute(let cmd) = multiSession.clauseCompleted("open zen", at: 3.5) { executedClauses.append(cmd) }

        _ = multiSession.ingest(partial: "open youtube.com", at: 5.0)
        if case .execute(let cmd) = multiSession.clauseCompleted("open youtube.com", at: 5.5) { executedClauses.append(cmd) }

        _ = multiSession.ingest(partial: "search youtube for lofi beats", at: 7.0)
        if case .execute(let cmd) = multiSession.clauseCompleted("search youtube for lofi beats", at: 7.5) { executedClauses.append(cmd) }

        let actionClose = multiSession.clauseCompleted("bye", at: 9.0)
        if case .close = actionClose { sessionClosed = true }

        precondition(executedClauses == ["open zen", "open youtube.com", "search youtube for lofi beats"])
        precondition(sessionClosed && multiSession.phase == .closing)

        print("Desktop checks passed, including repeated silence recovery, cancellation during recovery, preservation of real errors, preemption policy, and multi-clause wake session.")
    }
}
