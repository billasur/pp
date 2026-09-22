import Foundation

/// What a step is expected to change on screen, so "done" is a measurement rather than
/// the model's opinion about its own action.
public struct ExpectedEffect: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case appFrontmost
        case windowTitleContains
        case fieldContains
        case labelAppeared
        case labelDisappeared
        case contentMoved
        case none
    }

    public let kind: Kind
    public let value: String?

    public init(kind: Kind, value: String? = nil) {
        self.kind = kind; self.value = value
    }

    /// The effect each step kind is expected to have. Deterministic, and deliberately
    /// conservative: an effect we cannot observe is `none`, which is not treated as
    /// failure.
    public static func expected(for step: PlanStep) -> ExpectedEffect {
        switch step.kind {
        case .openApp: return ExpectedEffect(kind: .appFrontmost, value: step.target)
        case .openFolder: return ExpectedEffect(kind: .windowTitleContains, value: step.target)
        case .openURL: return ExpectedEffect(kind: .windowTitleContains, value: nil)
        case .typeText: return ExpectedEffect(kind: .fieldContains, value: step.text)
        case .click, .menu, .pressKey: return ExpectedEffect(kind: .contentMoved)
        case .focusInput: return ExpectedEffect(kind: .none)
        case .scroll, .skip: return ExpectedEffect(kind: .contentMoved)
        case .quitApp: return ExpectedEffect(kind: .labelDisappeared, value: step.target)
        }
    }
}

/// A cheap read of the screen taken before and after an action.
public struct ObservationSnapshot: Equatable, Sendable {
    public let app: String
    public let windowTitle: String
    public let labels: [String]
    public let focusedValue: String?
    public let fingerprint: String

    public init(app: String, windowTitle: String, labels: [String], focusedValue: String? = nil, fingerprint: String) {
        self.app = app; self.windowTitle = windowTitle; self.labels = labels
        self.focusedValue = focusedValue; self.fingerprint = fingerprint
    }

    public static func fingerprint(app: String, windowTitle: String, labels: [String]) -> String {
        ([app, windowTitle] + labels).joined(separator: "|")
    }

    public func contains(label: String?) -> Bool {
        guard let needle = label?.lowercased(), !needle.isEmpty else { return false }
        return labels.contains { $0.lowercased().contains(needle) }
    }
}

public enum VerificationOutcome: Equatable, Sendable {
    case done
    case retry(reason: String)
    case replan(reason: String)

    public var isDone: Bool { self == .done }
}

/// Decides done, retry, or replan — and enforces the retry budget so a failing step
/// cannot loop forever.
public enum Verifier {
    public static let defaultMaxAttempts = 3

    public static func verify(
        _ expected: ExpectedEffect,
        before: ObservationSnapshot,
        after: ObservationSnapshot,
        attempt: Int,
        maxAttempts: Int = Verifier.defaultMaxAttempts
    ) -> VerificationOutcome {
        if isSatisfied(expected, after: after) { return .done }

        let changed = after.fingerprint != before.fingerprint
        guard attempt < maxAttempts else {
            return .replan(reason: "the step did not take effect after \(maxAttempts) attempts")
        }
        if changed {
            // Something moved, but not where we needed it to. Repeating blindly would
            // repeat the same mistake.
            return .replan(reason: "the screen changed in an unexpected way")
        }
        return .retry(reason: "nothing changed on screen")
    }

    public static func isSatisfied(_ expected: ExpectedEffect, after: ObservationSnapshot) -> Bool {
        switch expected.kind {
        case .none:
            return true
        case .appFrontmost:
            guard let value = expected.value else { return true }
            return after.app.lowercased().contains(value.lowercased())
        case .windowTitleContains, .labelAppeared:
            return after.contains(label: expected.value)
        case .labelDisappeared:
            guard let value = expected.value else { return true }
            return !after.contains(label: value)
        case .fieldContains:
            guard let value = expected.value else { return true }
            return (after.focusedValue ?? "").contains(value)
        case .contentMoved:
            return true  // movement is checked through the fingerprint comparison
        }
    }
}

/// What was done, and what it would take to undo it.
///
/// pp does not pretend every action is reversible. Sending a message is not, so the
/// ledger records that honestly and the undo plan says so out loud.
public struct EffectedStep: Equatable, Sendable {
    public let summary: String
    public let kind: PlanStep.Kind
    public let target: String?
    public let reversible: Bool
    public let undoHint: String?

    public init(summary: String, kind: PlanStep.Kind, target: String?, reversible: Bool, undoHint: String?) {
        self.summary = summary; self.kind = kind; self.target = target
        self.reversible = reversible; self.undoHint = undoHint
    }
}

public final class EffectLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [EffectedStep] = []

    public init() {}

    public var entries: [EffectedStep] {
        lock.lock(); defer { lock.unlock() }
        return steps
    }

    public func record(_ step: PlanStep, previousApp: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        steps.append(EffectLedger.describe(step, previousApp: previousApp))
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        steps.removeAll()
    }

    /// Everything that cannot be undone, so the UI can be honest before acting.
    public var irreversible: [EffectedStep] {
        entries.filter { !$0.reversible }
    }

    /// Human-readable undo instructions, newest first.
    public func undoPlan() -> [String] {
        entries.reversed().compactMap { entry in
            guard let hint = entry.undoHint else { return nil }
            return entry.reversible ? hint : "Cannot undo: \(entry.summary). \(hint)"
        }
    }

    static func describe(_ step: PlanStep, previousApp: String?) -> EffectedStep {
        switch step.kind {
        case .click, .menu:
            let hazardous = ["send", "delete", "buy", "pay", "post", "submit", "share", "reply"]
            let text = "\(step.target ?? "")".lowercased()
            let irreversible = hazardous.contains { text.contains($0) }
            return EffectedStep(summary: step.summary, kind: step.kind, target: step.target,
                                reversible: !irreversible,
                                undoHint: irreversible ? "This cannot be undone." : "No undo needed for a press that changed nothing durable.")
        case .typeText:
            // Never store what was typed. The ledger is a record of actions, not of
            // content: typed text can be a password, a message, or a one-time code.
            let field = step.target ?? "the field"
            return EffectedStep(summary: "Type into \(field)", kind: step.kind, target: step.target,
                                reversible: true, undoHint: "Clear the text that was typed.")
        case .openApp, .openFolder, .openURL:
            return EffectedStep(summary: step.summary, kind: step.kind, target: step.target,
                                reversible: previousApp != nil, undoHint: previousApp.map { "Return to \($0)." })
        case .quitApp:
            return EffectedStep(summary: step.summary, kind: step.kind, target: step.target,
                                reversible: true, undoHint: step.target.map { "Reopen \($0)." })
        case .scroll, .skip:
            return EffectedStep(summary: step.summary, kind: step.kind, target: step.target,
                                reversible: false, undoHint: "Position is not restored.")
        case .pressKey, .focusInput:
            return EffectedStep(summary: step.summary, kind: step.kind, target: step.target,
                                reversible: true, undoHint: nil)
        }
    }
}
