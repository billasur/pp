import Foundation
import CoreGraphics

public enum IslandState: Equatable, Sendable {
    case idle
    case listening
    case heard(text: String)
    case working
    case result(text: String)
    case error(text: String)
    case alarm

    public var size: CGSize {
        switch self {
        case .idle:
            return CGSize(width: 220, height: 34)
        case .listening, .heard:
            return CGSize(width: 420, height: 64)
        case .working:
            return CGSize(width: 520, height: 96)
        case .result:
            return CGSize(width: 420, height: 64)
        case .error:
            return CGSize(width: 480, height: 72)
        case .alarm:
            return CGSize(width: 440, height: 68)
        }
    }

    public var autoHideDuration: TimeInterval? {
        switch self {
        case .idle, .listening, .heard, .working, .alarm:
            return nil
        case .result:
            return 2.5 // .result 2.5s
        case .error:
            return 6.0 // .error 6s
        }
    }

    /// True when a headline reports something pp could not do, so the island shows it as needing
    /// attention rather than as a verified result. "Alarm not set" must never wear a green tick.
    public static func reportsProblem(_ headline: String) -> Bool {
        if headline == "Command stopped" { return true }
        let lower = headline.lowercased()
        let markers = ["failed", "unavailable", "not set", "needs a time", "permission", "could not"]
        return markers.contains { lower.contains($0) }
    }
}
