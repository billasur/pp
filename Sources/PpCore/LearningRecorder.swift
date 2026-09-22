import Foundation

/// Turns commands pp has run into things pp can recall.
///
/// One place decides what is remembered: the history log, the ranking priors, and the
/// traces macros are mined from. Everything it writes passes `PrivacyFilter` first, so a
/// credential or a one-time code cannot reach the log, and a command that failed cannot
/// teach anything.
///
/// It never decides what to *do*. Recall only reorders and reuses; it can no more bypass
/// the safety critic than a preference can.
public final class LearningRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let history: EventLog?
    private let macros: MacroLibrary
    private let ranking: RankingModel
    private let minimumSupport: Int
    private let traceLimit: Int

    private var traces: [CommandTrace] = []
    private var running: (clause: String, app: String, steps: [PlanStep])?

    public init(history: EventLog?, macros: MacroLibrary, ranking: RankingModel,
                minimumSupport: Int = 3, traceLimit: Int = 400) {
        self.history = history
        self.macros = macros
        self.ranking = ranking
        self.minimumSupport = minimumSupport
        self.traceLimit = traceLimit
    }

    public var recordedTraces: [CommandTrace] {
        lock.lock(); defer { lock.unlock() }
        return traces
    }

    public func replaceTraces(_ saved: [CommandTrace]) {
        lock.lock(); defer { lock.unlock() }
        traces = saved
    }

    public func exportTraces() -> [CommandTrace] {
        lock.lock(); defer { lock.unlock() }
        return Array(traces.suffix(traceLimit))
    }

    /// Starts a command. Steps recorded before the next `begin` belong to this one.
    public func begin(clause: String, app: String) {
        lock.lock(); defer { lock.unlock() }
        running = (clause, app, [])
    }

    /// Records one executed step. The label is the control that was acted on, which is
    /// what the priors and the macro miner need; nothing else from the screen is kept.
    public func record(step: PlanStep?, label: String?, kind: String, signature: String,
                       app actedOn: String? = nil, roles: [String], succeeded: Bool) {
        lock.lock()
        guard let current = running else { lock.unlock(); return }
        lock.unlock()

        let event = InteractionEvent(
            at: Date(), clause: current.clause, app: actedOn ?? current.app,
            structureFingerprint: PrivacyFilter.structureFingerprint(roles: roles),
            actionKind: kind, targetLabel: label, succeeded: succeeded, stepSignature: signature)
        // The same gate covers the trace, not just the log. A step pp refuses to write down
        // must not be mined into a macro either, or the macro would replay a one-time code
        // the next time the same command is spoken.
        guard let kept = PrivacyFilter.cleaned(event) else { return }

        lock.lock()
        var steps = current.steps
        if let step { steps.append(step) }
        running = (current.clause, current.app, steps)
        lock.unlock()
        try? history?.append(kept)
        ranking.observe(kept)
    }

    /// Ends the command. Only a command that worked, and that has steps, becomes a trace.
    public func finish(succeeded: Bool) {
        lock.lock()
        guard let current = running else { lock.unlock(); return }
        running = nil
        lock.unlock()
        guard succeeded, !current.steps.isEmpty else { return }
        lock.lock()
        traces.append(CommandTrace(clause: current.clause, steps: current.steps, succeeded: true, app: current.app))
        lock.unlock()
        mine()
    }

    /// Repetition is the only evidence accepted: a shape that worked `minimumSupport`
    /// times becomes a macro.
    @discardableResult
    public func mine(now: Date = Date()) -> [Macro] {
        let mined = MacroMiner.mine(traces: recordedTraces, minimumSupport: minimumSupport, now: now)
        let known = Set(macros.all().map(\.id))
        var added: [Macro] = []
        for macro in mined where !known.contains(macro.id) {
            // A macro the user switched off stays off: mining adds, it never re-enables.
            macros.insert(macro)
            added.append(macro)
        }
        return added
    }

    /// A macro for this command, if the same command has worked before. Retrieved before
    /// the model runs, so a repeat costs milliseconds instead of a model call.
    public func macro(for clause: String, app: String?) -> Macro? {
        guard let macro = macros.bestMatch(for: clause, app: app) else { return nil }
        var used = macro
        used.successCount += 1
        used.lastUsedAt = Date()
        macros.insert(used)
        return macro
    }
}
