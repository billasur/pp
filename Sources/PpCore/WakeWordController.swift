import Foundation

/// Microphone state, wake-word gating, and the kill switch.
///
/// The privacy promise in code: audio is held only while the wake phrase or hold-to-talk
/// is active, the buffer is dropped on every other path, and nothing is ever written to
/// disk. The kill switch stops capture before the next buffer is accepted.
public final class WakeWordController: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case off
        case listeningForWake
        case capturingCommand
    }

    public enum Outcome: Equatable, Sendable {
        /// Wake phrase heard; the command buffer begins now.
        case woke(command: String)
        /// Audio heard but no wake phrase yet.
        case buffered
        /// Wake phrase heard on its own; waiting for the command.
        case armed
        /// Capture is off; this audio was not accepted.
        case rejected
    }

    private let lock = NSLock()
    private let phrase: String
    private var state: State = .off
    private var retainedWords: [String] = []
    private var killed = false

    public init(phrase: String = "Hey pp") {
        self.phrase = phrase
    }

    public var currentState: State {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    /// Whether audio is currently being kept. Read by the UI.
    public var isCapturing: Bool {
        lock.lock(); defer { lock.unlock() }
        return state != .off
    }

    /// Nothing is ever persisted.
    public var writesToDisk: Bool { false }

    public func armForWake() {
        lock.lock(); defer { lock.unlock() }
        guard !killed else { return }
        state = .listeningForWake
        retainedWords.removeAll()
    }

    public func beginCommand() {
        lock.lock(); defer { lock.unlock() }
        guard !killed else { return }
        state = .capturingCommand
    }

    /// The kill switch. Stops accepting audio immediately and forgets the buffer.
    public func kill() {
        lock.lock(); defer { lock.unlock() }
        killed = true
        state = .off
        retainedWords.removeAll()
    }

    public func rearmAfterKill() {
        lock.lock(); defer { lock.unlock() }
        killed = false
        state = .off
    }

    /// Feeds a partial transcript. In wake mode, audio is retained only until the
    /// phrase fires; in command mode everything is kept for the decision.
    public func ingest(partial: String) -> Outcome {
        lock.lock(); defer { lock.unlock() }
        guard !killed, state != .off else { return .rejected }

        switch state {
        case .off:
            return .rejected
        case .listeningForWake:
            if let command = WakePhrase.command(in: partial, after: phrase) {
                if command.isEmpty {
                    state = .capturingCommand
                    retainedWords.removeAll()
                    return .armed
                }
                state = .capturingCommand
                retainedWords = PartialRouter.tokens(command)
                return .woke(command: command)
            }
            // Not the wake phrase: hold nothing.
            retainedWords.removeAll()
            return .buffered
        case .capturingCommand:
            retainedWords = PartialRouter.tokens(partial)
            return .buffered
        }
    }

    /// Words currently held. Empty unless the wake phrase fired or hold-to-talk is on.
    public var retainedWordsSnapshot: [String] {
        lock.lock(); defer { lock.unlock() }
        return retainedWords
    }

    /// Called when a command finishes: the buffer is discarded either way.
    public func finishCommand() {
        lock.lock(); defer { lock.unlock() }
        retainedWords.removeAll()
        state = killed ? .off : .listeningForWake
    }
}
