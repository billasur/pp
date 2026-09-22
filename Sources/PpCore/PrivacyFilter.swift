import CryptoKit
import Foundation

/// One thing pp learned to do.
public struct InteractionEvent: Codable, Equatable, Sendable {
    public let id: UUID
    public let at: Date
    /// The spoken clause, which is the user's own request and safe to keep.
    public let clause: String
    public let app: String
    /// A fingerprint of the *structure* of the screen, never the page or message text.
    public let structureFingerprint: String
    public let actionKind: String
    /// The label of the control that was used, so ranking can prefer it next time.
    public let targetLabel: String?
    public let succeeded: Bool
    /// Signature of the step list, which is what macro mining groups on.
    public let stepSignature: String

    public init(id: UUID = UUID(), at: Date, clause: String, app: String, structureFingerprint: String,
                actionKind: String, targetLabel: String?, succeeded: Bool, stepSignature: String) {
        self.id = id; self.at = at; self.clause = clause; self.app = app
        self.structureFingerprint = structureFingerprint; self.actionKind = actionKind
        self.targetLabel = targetLabel; self.succeeded = succeeded; self.stepSignature = stepSignature
    }
}

/// Decides what may be written down.
///
/// This is a release gate, not a nicety: pp reads the screen, so the boundary between
/// "the user asked for this" and "what happened to be on screen" is the whole privacy
/// story. The rules are deny-by-default for anything that looks like a credential and
/// forbid page or message bodies entirely.
public enum PrivacyFilter {
    /// Field names that mean "do not record anything about this".
    public static let forbiddenFieldNames: Set<String> = [
        "password", "passcode", "passwd", "pin", "cvv", "cvc", "card number",
        "credit card", "debit card", "ssn", "social security", "security code",
        "verification code", "one-time", "one time code", "otp", "2fa", "two-factor",
        "secret", "token", "api key", "apikey", "recovery code", "seed phrase",
        "security answer", "routing number", "iban", "sort code", "expiry", "exp date"
    ]

    /// Substrings that mark a string as secret-bearing wherever it appears.
    private static let secretMarkers = [
        "sk-", "ghp_", "gho_", "AKIA", "Bearer ", "-----BEGIN", "xoxb-", "xoxp-"
    ]

    public static func isSensitiveField(_ label: String) -> Bool {
        let lowered = label.lowercased()
        return forbiddenFieldNames.contains { lowered.contains($0) }
    }

    /// Words that make a nearby number a credential rather than a quantity.
    private static let codeContextWords = [
        "code", "pin", "otp", "passcode", "password", "verification", "verify",
        "security", "token", "cvv", "cvc", "expires", "expiry", "card", "iban",
        "account", "routing", "ssn", "social"
    ]

    /// True when the text looks like a credential or a one-time code rather than prose.
    ///
    /// This has to work on *labels*, not just on bare numbers: "Code field: 483920" is a
    /// one-time code sitting inside a sentence, and a rule that only recognised a pure
    /// digit string would store it.
    public static func looksLikeSecret(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        if secretMarkers.contains(where: { trimmed.contains($0) }) { return true }

        let digitRuns = runsOfDigits(in: trimmed)
        guard !digitRuns.isEmpty else { return false }

        // A card-like run is a secret wherever it appears.
        if digitRuns.contains(where: { (13...19).contains($0.count) }) { return true }

        let hasContext = codeContextWords.contains { lowered.contains($0) }
        let bareText = trimmed.allSatisfy { $0.isNumber || $0.isWhitespace || $0 == "-" }
        if bareText, digitRuns.contains(where: { (4...8).contains($0.count) }) { return true }
        if hasContext, digitRuns.contains(where: { (4...10).contains($0.count) }) { return true }

        return false
    }

    /// Consecutive digit runs, so "483920" and "Code field: 483920" both yield one.
    static func runsOfDigits(in text: String) -> [String] {
        var runs: [String] = []
        var current = ""
        for character in text {
            if character.isNumber {
                current.append(character)
            } else if !current.isEmpty {
                runs.append(current)
                current = ""
            }
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    /// The single gate every stored record passes through. Returns nil when the event
    /// must not be written at all.
    public static func cleaned(_ event: InteractionEvent) -> InteractionEvent? {
        guard event.succeeded else { return nil }
        if let label = event.targetLabel {
            if isSensitiveField(label) { return nil }
            if looksLikeSecret(label) { return nil }
        }
        if looksLikeSecret(event.clause) { return nil }
        return event
    }

    /// Structural fingerprint: the shape of the screen, not its contents.
    public static func structureFingerprint(roles: [String]) -> String {
        let histogram = roles.sorted().joined(separator: ",")
        return SHA256.hash(data: Data(histogram.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    /// Fingerprint of a target, so "the same button as last time" is recognisable
    /// without keeping a copy of whatever it said.
    public static func targetFingerprint(label: String, role: String) -> String {
        let value = "\(role)|\(label.lowercased())"
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16).description
    }
}
