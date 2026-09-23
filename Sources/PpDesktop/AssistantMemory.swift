import Foundation
import AVFoundation
import Speech
import UserNotifications
import EventKit
import AppKit
import PpCore
import os

/// What pp remembers on this Mac: the history of what it did, and what it learned from
/// that history.
///
/// Everything here is optional at runtime. A missing, corrupt or unwritable store leaves
/// the assistant fully working, only without recall — recall is never allowed to be the
/// reason a command fails.
@MainActor
final class AssistantMemory {
    static let shared = AssistantMemory()

    private static let log = Logger(subsystem: "local.pp", category: "memory")

    /// Successful commands become macros after this many repetitions. Three is the point
    /// where "it does this a lot" is a fair description rather than a coincidence.
    static let minimumSupport = 3
    /// Traces are the raw material for mining, so they are capped rather than kept forever.
    static let traceLimit = 400

    let macros = MacroLibrary()
    let ranking = RankingModel()
    private(set) var store: PersonalizationStore
    private(set) var history: EventLog?
    /// The one place that decides what is remembered. `PpCore` owns the rules so they can
    /// be tested without a UI, an app or a screen.
    private(set) var recorder: LearningRecorder

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("pp")
    }

    private static var bundleURL: URL { directory.appendingPathComponent("personalization.json") }
    private static var traceURL: URL { directory.appendingPathComponent("traces.json") }
    private static var historyURL: URL { directory.appendingPathComponent("history.sqlite") }

    private init() {
        let macros = self.macros
        let history = try? EventLog(path: Self.historyURL)
        store = PersonalizationStore(macros: macros, ranking: ranking)
        self.history = history
        recorder = LearningRecorder(history: history, macros: macros, ranking: ranking,
                                    minimumSupport: Self.minimumSupport, traceLimit: Self.traceLimit)
    }

    // MARK: - Lifecycle

    func load() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)

        if let data = try? Data(contentsOf: Self.bundleURL) {
            do { try store.importBundle(data) } catch {
                Self.log.error("learned data did not load: \(error.localizedDescription, privacy: .public)")
            }
        }
        if let data = try? Data(contentsOf: Self.traceURL),
           let saved = try? PpJSON.decoder().decode([CommandTrace].self, from: data) {
            recorder.replaceTraces(saved)
        }

        // The log is the source of truth for these: they are counts of what actually
        // happened, and the log is the record of what actually happened.
        let recent = history.flatMap { try? $0.recent(2000) } ?? []
        if !recent.isEmpty { ranking.replaceFeatures(RankingFeatures.learn(from: recent)) }

        Self.log.notice("remembering \(recent.count) actions, \(self.macros.all().count) learned items")
    }

    func shutdown() {
        finish(succeeded: false)
        save()
    }

    private func save() {
        do {
            try store.export().write(to: Self.bundleURL, options: .atomic)
            try PpJSON.encoder().encode(recorder.exportTraces()).write(to: Self.traceURL, options: .atomic)
        } catch {
            Self.log.error("could not save what pp learned: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Recording

    func begin(clause: String, app: String) {
        recorder.begin(clause: clause, app: app)
    }

    func record(step: PlanStep?, label: String?, kind: String, signature: String, app actedOn: String? = nil,
                roles: [String], succeeded: Bool) {
        recorder.record(step: step, label: label, kind: kind, signature: signature,
                        app: actedOn, roles: roles, succeeded: succeeded)
    }

    func finish(succeeded: Bool) {
        recorder.finish(succeeded: succeeded)
        if succeeded { save() }
    }

    // MARK: - Recall

    /// A macro for this command, if the same command has worked before. Retrieved before
    /// the model runs, so a repeat costs milliseconds instead of a model call.
    func macro(for clause: String, app: String?) -> Macro? {
        recorder.macro(for: clause, app: app)
    }

    // MARK: - Inspection

    func items() -> [PersonalizationItem] { store.items() }

    /// Writes what is in memory now. Called after the user edits anything in the list.
    func commit() { save() }

    func historyCount() -> Int { (try? history?.count()) ?? 0 }

    func recentHistory(_ limit: Int = 50) -> [InteractionEvent] { (try? history?.recent(limit)) ?? [] }

    func exportEverything() throws -> Data { try store.export() }

    func importEverything(_ data: Data) throws {
        try store.importBundle(data)
        save()
    }

    /// The "delete everything" promise, in one place: learned items, the traces they were
    /// mined from, and the history log they were counted from.
    func deleteEverything() {
        store.deleteEverything()
        recorder.replaceTraces([])
        try? history?.deleteAll()
        try? FileManager.default.removeItem(at: Self.bundleURL)
        try? FileManager.default.removeItem(at: Self.traceURL)
        ranking.replaceFeatures(RankingFeatures())
        Self.log.notice("deleted everything pp had learned")
    }
}

extension DesktopSnapshot {
    /// The kinds of thing on screen, for the structural fingerprint: roles and placement,
    /// never what any of them says.
    var candidateRoles: [String] {
        candidates.compactMap { candidate in
            guard let role = meta[candidate.id]?.role else { return nil }
            return meta[candidate.id]?.place.map { "\(role):\($0)" } ?? role
        }
    }

    func eventKind(of candidate: Candidate) -> String {
        switch kinds[candidate.id] ?? .control {
        case .app: return PlanStep.Kind.openApp.rawValue
        case .quit: return PlanStep.Kind.quitApp.rawValue
        case .website: return PlanStep.Kind.openURL.rawValue
        case .folder: return PlanStep.Kind.openFolder.rawValue
        case .input: return PlanStep.Kind.typeText.rawValue
        case .focus: return PlanStep.Kind.focusInput.rawValue
        case .menu: return PlanStep.Kind.menu.rawValue
        case .key: return PlanStep.Kind.pressKey.rawValue
        case .window, .control: return PlanStep.Kind.click.rawValue
        }
    }

    /// The same thing as a plan step, so a command that worked can be repeated as a macro.
    func planStep(of candidate: Candidate) -> PlanStep {
        let kind: PlanStep.Kind
        switch kinds[candidate.id] ?? .control {
        case .app: kind = .openApp
        case .quit: kind = .quitApp
        case .website: kind = .openURL
        case .folder: kind = .openFolder
        case .input: kind = .typeText
        case .focus: kind = .focusInput
        case .menu: kind = .menu
        case .key: kind = .pressKey
        case .window, .control: kind = .click
        }
        return PlanStep(kind: kind, target: candidate.label)
    }
}

/// The real permission state, read from the system. Kept in its own type so the
/// onboarding flow can be exercised with a probe that grants itself.
struct MacPermissionProbe: PermissionProbing {
    func status(of kind: PermissionKind) -> PermissionStatus {
        switch kind {
        case .accessibility:
            return Desktop.hasAccess ? .granted : .denied
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .granted
            case .notDetermined: return .notDetermined
            default: return .denied
            }
        case .speechRecognition:
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized: return .granted
            case .notDetermined: return .notDetermined
            default: return .denied
            }
        case .appleEvents:
            // Check Apple Events automation status via AEDeterminePermissionToAutomateTarget
            let targetAEDesc: NSAppleEventDescriptor
            if #available(macOS 11.0, *) {
                targetAEDesc = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
            } else {
                targetAEDesc = NSAppleEventDescriptor()
            }
            let status = AEDeterminePermissionToAutomateTarget(targetAEDesc.aeDesc, typeWildCard, typeWildCard, false)
            switch status {
            case noErr: return .granted
            case OSStatus(errAEEventNotPermitted): return .denied
            default: return .notDetermined
            }
        case .calendars:
            let status = EKEventStore.authorizationStatus(for: .event)
            switch status {
            case .authorized, .fullAccess: return .granted
            case .notDetermined: return .notDetermined
            default: return .denied
            }
        case .notifications:
            let semaphore = DispatchSemaphore(value: 0)
            var grantedStatus: PermissionStatus = .notDetermined
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                switch settings.authorizationStatus {
                case .authorized, .provisional: grantedStatus = .granted
                case .notDetermined: grantedStatus = .notDetermined
                default: grantedStatus = .denied
                }
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 0.2)
            return grantedStatus
        }
    }

    func request(_ kind: PermissionKind) {
        switch kind {
        case .accessibility: Desktop.requestAccess()
        case .microphone: AVCaptureDevice.requestAccess(for: .audio) { _ in }
        case .speechRecognition: SFSpeechRecognizer.requestAuthorization { _ in }
        case .appleEvents:
            let targetAEDesc = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
            _ = AEDeterminePermissionToAutomateTarget(targetAEDesc.aeDesc, typeWildCard, typeWildCard, true)
        case .calendars:
            let store = EKEventStore()
            if #available(macOS 14.0, *) {
                store.requestFullAccessToEvents { _, _ in }
            } else {
                store.requestAccess(to: .event) { _, _ in }
            }
        case .notifications:
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }
}
