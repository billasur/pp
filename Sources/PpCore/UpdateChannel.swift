import CryptoKit
import Foundation

/// pp updates in two independent lanes. An app update is a few megabytes of code; a
/// model update is hundreds of megabytes of weights. Mixing them is how a "small
/// update" turns into a 3 GB download, so the shapes are checked rather than trusted.
public enum UpdateChannel: String, Codable, Sendable {
    case app
    case models
}

public struct UpdateManifest: Codable, Equatable, Sendable {
    public let channel: UpdateChannel
    public let version: String
    public let url: URL
    public let sha256: String
    public let minAppVersion: String?
    /// Declared payload contents, so the policy can check the shape matches the lane.
    public let containsModelWeights: Bool
    public let containsExecutable: Bool

    public init(channel: UpdateChannel, version: String, url: URL, sha256: String,
                minAppVersion: String? = nil, containsModelWeights: Bool, containsExecutable: Bool) {
        self.channel = channel; self.version = version; self.url = url; self.sha256 = sha256
        self.minAppVersion = minAppVersion
        self.containsModelWeights = containsModelWeights; self.containsExecutable = containsExecutable
    }
}

public enum UpdateError: LocalizedError, Equatable {
    case appUpdateCarriesWeights
    case modelUpdateCarriesExecutable
    case checksumMismatch
    case requiresNewerApp(required: String, current: String)
    case unsigned

    public var errorDescription: String? {
        switch self {
        case .appUpdateCarriesWeights:
            return "That app update contains model weights, so it would force a large download. App and model updates must stay separate."
        case .modelUpdateCarriesExecutable:
            return "That model package contains executable code. Model packages are data only."
        case .checksumMismatch:
            return "The download did not match its checksum and was discarded."
        case .requiresNewerApp(let required, let current):
            return "This update needs pp \(required) or newer. You are running \(current)."
        case .unsigned:
            return "The update is not signed, so it was not installed."
        }
    }
}

public enum UpdatePolicy {
    /// Rejects an update whose shape does not match its lane.
    public static func validate(_ manifest: UpdateManifest, currentAppVersion: String) throws {
        switch manifest.channel {
        case .app:
            if manifest.containsModelWeights { throw UpdateError.appUpdateCarriesWeights }
            if !manifest.containsExecutable { throw UpdateError.unsigned }
        case .models:
            if manifest.containsExecutable { throw UpdateError.modelUpdateCarriesExecutable }
            if manifest.containsModelWeights == false { throw UpdateError.checksumMismatch }
        }
        if let required = manifest.minAppVersion,
           PpVersion.compare(currentAppVersion, required) < 0 {
            throw UpdateError.requiresNewerApp(required: required, current: currentAppVersion)
        }
    }

    /// True when applying this update can leave an existing model untouched.
    public static func leavesModelsUntouched(_ manifest: UpdateManifest) -> Bool {
        manifest.channel == .app && !manifest.containsModelWeights
    }
}

public enum UpdateVerifier {
    public static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Checks the payload against the manifest before anything is unpacked.
    public static func verify(payload: Data, against manifest: UpdateManifest) throws {
        guard sha256(of: payload).lowercased() == manifest.sha256.lowercased() else {
            throw UpdateError.checksumMismatch
        }
    }

    /// True when the code signature is attached and valid. An update without one is
    /// never installed, whatever it claims.
    public static func isSigned(executable: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--strict", executable.path]
        process.standardError = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
