import Foundation

/// One recognised piece of speech, or a terminal signal from the recogniser.
public struct SpeechUpdate: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case partial
        case final
        case idle
        case failure
    }

    public let kind: Kind
    public let text: String

    public init(kind: Kind, text: String = "") {
        self.kind = kind
        self.text = text
    }
}

/// A speech-to-text source. Every implementation must work with the network off.
@MainActor
public protocol SpeechProviding: AnyObject {
    var onUpdate: ((SpeechUpdate) -> Void)? { get set }
    var isListening: Bool { get }
    var engineDescription: String { get }
    func start(handsFree: Bool, wakePhrase: String?) throws
    func stop()
    func cancel()
}

/// Rolling audio policy: audio is held only while a wake phrase or hold-to-talk is
/// active, and is never written to disk.
public struct AudioRetentionPolicy: Sendable {
    public enum Decision: Sendable, Equatable {
        case discard
        case retain
    }

    public let wakePhrase: String?
    public let holdToTalk: Bool

    public init(wakePhrase: String?, holdToTalk: Bool) {
        self.wakePhrase = wakePhrase
        self.holdToTalk = holdToTalk
    }

    /// Whether the rolling buffer may be retained for this utterance.
    public func decide(heardWakePhrase: Bool) -> Decision {
        if holdToTalk || heardWakePhrase { return .retain }
        return .discard
    }

    /// Nothing is ever persisted, regardless of decision.
    public var writesToDisk: Bool { false }
}

/// Scripted speech source for tests and replay. It performs no audio capture.
@MainActor
public final class FakeSpeechProvider: SpeechProviding {
    public private(set) var isListening = false
    public let engineDescription = "fake"
    public var onUpdate: ((SpeechUpdate) -> Void)?
    public private(set) var startCount = 0
    public private(set) var stopCount = 0

    private var queued: [SpeechUpdate] = []

    public init() {}

    public func start(handsFree: Bool, wakePhrase: String?) throws {
        isListening = true
        startCount += 1
        queued.forEach { onUpdate?($0) }
        queued.removeAll()
    }

    public func stop() {
        isListening = false
        stopCount += 1
    }

    public func cancel() {
        isListening = false
        stopCount += 1
    }

    /// Emits a scripted partial transcript.
    public func emit(partial text: String) {
        deliver(SpeechUpdate(kind: .partial, text: text))
    }

    /// Emits a scripted final transcript and ends listening.
    public func emit(final text: String) {
        isListening = false
        deliver(SpeechUpdate(kind: .final, text: text))
    }

    public func emitIdle() {
        deliver(SpeechUpdate(kind: .idle))
    }

    public func emitFailure(_ message: String) {
        deliver(SpeechUpdate(kind: .failure, text: message))
    }

    private func deliver(_ update: SpeechUpdate) {
        guard let onUpdate else {
            queued.append(update)
            return
        }
        onUpdate(update)
    }
}
