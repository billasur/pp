import Foundation

/// The macOS permissions pp needs, and nothing more.
public enum PermissionKind: String, Sendable, CaseIterable {
    case accessibility
    case microphone
    case speechRecognition

    public var title: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .microphone: return "Microphone"
        case .speechRecognition: return "Speech recognition"
        }
    }

    public var explanation: String {
        switch self {
        case .accessibility:
            return "pp reads the controls on screen and clicks them for you. It reads labels, never the contents of secure fields."
        case .microphone:
            return "pp listens only while you hold the shortcut or after you say the wake phrase."
        case .speechRecognition:
            return "Your speech is transcribed on this Mac. pp never sends audio anywhere."
        }
    }

    /// System Settings pane that grants this permission.
    public var settingsURL: URL {
        switch self {
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        case .microphone:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        case .speechRecognition:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")!
        }
    }
}

public enum PermissionStatus: String, Sendable, Equatable {
    case granted
    case denied
    case notDetermined

    public var isGranted: Bool { self == .granted }
}

/// Reads and requests permissions. Injected so the flow can be tested without TCC.
public protocol PermissionProbing: Sendable {
    func status(of kind: PermissionKind) -> PermissionStatus
    /// Asks the system to prompt. May be a no-op for Accessibility, which only the
    /// user can grant in System Settings.
    func request(_ kind: PermissionKind)
}

/// Where the user is in setup.
public enum OnboardingStep: Equatable, Sendable {
    case welcome
    case needsPermission(PermissionKind)
    case needsModel
    case ready
}

/// Guides the first run.
///
/// The hard-won detail: a user who grants Accessibility must come back to the app, and
/// an app that does not notice the grant looks broken. So the coordinator is polled
/// rather than asking once, and it always names the exact permission still missing.
public final class OnboardingCoordinator: @unchecked Sendable {
    private let probe: any PermissionProbing
    private let modelReady: @Sendable () -> Bool

    public init(probe: any PermissionProbing, modelReady: @escaping @Sendable () -> Bool) {
        self.probe = probe
        self.modelReady = modelReady
    }

    public func statuses() -> [(PermissionKind, PermissionStatus)] {
        PermissionKind.allCases.map { ($0, probe.status(of: $0)) }
    }

    /// The single next thing the user has to do.
    public func currentStep() -> OnboardingStep {
        for kind in PermissionKind.allCases where !probe.status(of: kind).isGranted {
            return .needsPermission(kind)
        }
        return modelReady() ? .ready : .needsModel
    }

    public func request(_ kind: PermissionKind) {
        probe.request(kind)
    }

    /// True once every permission is granted, whatever the model situation.
    public var permissionsSatisfied: Bool {
        PermissionKind.allCases.allSatisfy { probe.status(of: $0).isGranted }
    }
}

/// Checks the required permissions once a second until they are all granted.
///
/// macOS gives no callback when a user flips a switch in System Settings, so polling is
/// the only correct approach. Runs until cancelled.
public struct PermissionPoller: Sendable {
    public let interval: TimeInterval
    public init(interval: TimeInterval = 1.0) { self.interval = interval }

    public func run(coordinator: OnboardingCoordinator,
                    onSatisfied: @escaping @Sendable () -> Void) -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                if coordinator.permissionsSatisfied {
                    onSatisfied()
                    return
                }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }
}
