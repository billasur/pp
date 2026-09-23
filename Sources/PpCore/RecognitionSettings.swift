import Foundation

/// Recognition accuracy and privacy preference.
public enum RecognitionMode: String, CaseIterable, Identifiable, Sendable {
    case onDevice = "onDevice"
    case preferAppleServers = "preferAppleServers"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .onDevice:
            return "On-device (Private)"
        case .preferAppleServers:
            return "Apple Servers (Higher accuracy)"
        }
    }

    public var description: String {
        switch self {
        case .onDevice:
            return "Audio is processed 100% on your Mac using the Apple Neural Engine. Fast and completely offline."
        case .preferAppleServers:
            return "Audio is sent to Apple's speech recognition servers for higher accuracy on short or uncommon words."
        }
    }
}

public final class RecognitionSettings: @unchecked Sendable {
    public static let shared = RecognitionSettings()

    private let defaultsKey = "RecognitionMode"
    private let lock = NSLock()
    private var cachedMode: RecognitionMode

    public init() {
        let saved = UserDefaults.standard.string(forKey: "RecognitionMode") ?? RecognitionMode.onDevice.rawValue
        self.cachedMode = RecognitionMode(rawValue: saved) ?? .onDevice
    }

    public var mode: RecognitionMode {
        get {
            lock.lock()
            defer { lock.unlock() }
            return cachedMode
        }
        set {
            lock.lock()
            cachedMode = newValue
            lock.unlock()
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
        }
    }
}
