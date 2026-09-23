import Foundation

/// Outcome of ingesting a partial transcript into a WakeSession.
public enum WakeSessionOutcome: Equatable, Sendable {
    case ignored
    case woke(command: String)
    case inSession(partial: String)
    case dismissed
    case cancelled
}

/// Action to perform when an utterance/clause completes within a WakeSession.
public enum SessionAction: Equatable, Sendable {
    case execute(String)
    case close
    case none
}

/// Pure state machine governing wake word detection and ongoing multi-command session lifecycle.
public struct WakeSession: Sendable {
    public enum Phase: String, Sendable, Equatable {
        case idle
        case wakeListening
        case session
        case closing
    }

    public private(set) var phase: Phase
    public private(set) var lastSpeechTime: TimeInterval
    public let sessionIdleSeconds: TimeInterval

    public init(sessionIdleSeconds: TimeInterval = 300.0, initialPhase: Phase = .wakeListening, initialTime: TimeInterval = 0) {
        self.sessionIdleSeconds = sessionIdleSeconds
        self.phase = initialPhase
        self.lastSpeechTime = initialTime
    }

    public mutating func armForWake(at currentTime: TimeInterval = 0) {
        phase = .wakeListening
        lastSpeechTime = currentTime
    }

    public mutating func checkTimeout(at currentTime: TimeInterval) -> Bool {
        guard phase == .session else { return false }
        if currentTime - lastSpeechTime >= sessionIdleSeconds {
            phase = .closing
            return true
        }
        return false
    }

    public mutating func ingest(partial: String, at currentTime: TimeInterval = 0) -> WakeSessionOutcome {
        let trimmed = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .ignored }

        if let dismissal = DismissalPhrase.match(trimmed) {
            phase = .closing
            return dismissal == .cancel ? .cancelled : .dismissed
        }

        switch phase {
        case .idle:
            return .ignored

        case .wakeListening:
            if let match = WakeMatcher.match(in: trimmed) {
                phase = .session
                lastSpeechTime = currentTime
                return .woke(command: match.command)
            } else if let command = WakePhrase.command(in: trimmed, after: "Hey pp") {
                phase = .session
                lastSpeechTime = currentTime
                return .woke(command: command)
            }
            return .ignored

        case .session:
            lastSpeechTime = currentTime
            return .inSession(partial: trimmed)

        case .closing:
            return .ignored
        }
    }

    public mutating func clauseCompleted(_ text: String, at currentTime: TimeInterval = 0) -> SessionAction {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }

        lastSpeechTime = currentTime

        if let _ = DismissalPhrase.match(trimmed) {
            phase = .closing
            return .close
        }

        switch phase {
        case .wakeListening:
            if let match = WakeMatcher.match(in: trimmed) {
                phase = .session
                if match.command.isEmpty {
                    return .none
                }
                return .execute(match.command)
            } else if let command = WakePhrase.command(in: trimmed, after: "Hey pp") {
                phase = .session
                if command.isEmpty {
                    return .none
                }
                return .execute(command)
            }
            return .none

        case .session:
            if let match = WakeMatcher.match(in: trimmed) {
                if match.command.isEmpty {
                    return .none
                }
                return .execute(match.command)
            } else if let command = WakePhrase.command(in: trimmed, after: "Hey pp") {
                if command.isEmpty {
                    return .none
                }
                return .execute(command)
            }
            return .execute(trimmed)

        case .idle, .closing:
            return .none
        }
    }

    public mutating func close() {
        phase = .closing
    }

    public mutating func resetToIdle() {
        phase = .idle
    }
}
