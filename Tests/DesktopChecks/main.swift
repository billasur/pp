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
        precondition(WakePhrase.command(in: "Hey p p, open Finder", after: "Hey pp") == "open Finder")
        precondition(WakePhrase.command(in: "Hey pee pee, open Finder", after: "Hey pp") == "open Finder")
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
        precondition(failures == 4 && !delivered, "Partial speech must never execute after an error")
        print("Desktop checks passed, including repeated silence recovery, cancellation during recovery, and preservation of real errors.")
    }
}
