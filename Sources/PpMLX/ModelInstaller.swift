import CryptoKit
import Foundation

/// Installs model packages atomically.
///
/// Nothing becomes active until the whole package is downloaded to a staging
/// directory, every checksum matches, and a smoke inference succeeds. Activation is a
/// rename on one volume, so an interrupted install leaves the previous package
/// untouched and the app always has something loadable — or nothing, never a broken
/// half-model.
public enum ModelInstaller {

    public enum InstallError: LocalizedError, Equatable {
        case insufficientDisk(required: Int64, available: Int64)
        case smokeTestFailed(String)
        case nothingToRollBackTo
        case rollbackTargetUnverified
        case activationFailed(String)

        public var errorDescription: String? {
            switch self {
            case .insufficientDisk(let required, let available):
                let need = ByteCountFormatter.string(fromByteCount: required, countStyle: .file)
                let have = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
                return "Not enough free disk space. The package needs about \(need) and only \(have) is available."
            case .smokeTestFailed(let reason):
                return "The downloaded model failed its smoke test, so it was not activated: \(reason)"
            case .nothingToRollBackTo:
                return "There is no previous model package to roll back to."
            case .rollbackTargetUnverified:
                return "The previous model package no longer matches its checksums, so it was not restored."
            case .activationFailed(let reason):
                return "The model package could not be activated: \(reason)"
            }
        }
    }

    /// Headroom multiplier: staging plus the active package must both fit.
    public static let diskSafetyMultiplier = 2.2

    // MARK: Install

    /// Downloads, validates, verifies and activates a package.
    /// - Parameter smokeTest: run against the staged package before it can become
    ///   active. The default loads the model and performs one inference.
    @discardableResult
    public static func install(
        from source: any ModelFileSource,
        root: URL = ModelManager.rootDirectory,
        appVersion: String = ModelManager.currentVersion,
        smokeTest: ((URL) throws -> Void)? = nil,
        progress: (@Sendable (ModelDownloader.State) -> Void)? = nil
    ) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        // 1. Manifest first. An incompatible package is rejected while it is inert.
        progress?(.verifying)
        let manifestData = try await source.manifestData()
        let manifest = try JSONDecoder().decode(ModelManager.Manifest.self, from: manifestData)
        try ModelManager.validate(manifest, appVersion: appVersion)

        // 2. Disk space, before writing a single byte.
        // 2.2x headroom expressed in integers so it cannot overflow or round down.
        let (scaled, overflow) = manifest.totalBytes.multipliedReportingOverflow(by: 22)
        let required = overflow ? Int64.max : scaled / 10
        if let available = availableCapacity(at: root), available < required {
            throw InstallError.insufficientDisk(required: required, available: available)
        }

        // 3. Stage every file, verifying size and hash as it lands.
        let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        var completed = false
        defer { if !completed { try? fm.removeItem(at: staging) } }

        try manifestData.write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)

        let ordered = manifest.files.keys.sorted()
        var received: Int64 = 0
        for (index, name) in ordered.enumerated() {
            guard let expected = manifest.files[name] else { continue }
            let destination = staging.appendingPathComponent(name)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            progress?(.downloading(currentFile: name, fileIndex: index + 1, totalFiles: ordered.count,
                                   bytesReceived: received, totalBytes: manifest.totalBytes))
            let alreadyReceived = received
            try await source.fetch(name, expectedSize: expected.sizeBytes, to: destination, progress: ProgressSink { written in
                progress?(.downloading(currentFile: name, fileIndex: index + 1, totalFiles: ordered.count,
                                       bytesReceived: alreadyReceived + written, totalBytes: manifest.totalBytes))
            })
            received += expected.sizeBytes

            let attributes = try? fm.attributesOfItem(atPath: destination.path)
            guard let size = attributes?[.size] as? Int64, size == expected.sizeBytes else {
                throw InstallError.smokeTestFailed("\(name) arrived with the wrong size")
            }
            guard let hash = try? ModelManager.computeSHA256(of: destination), hash.lowercased() == expected.sha256.lowercased() else {
                throw InstallError.smokeTestFailed("\(name) failed checksum verification")
            }
        }

        guard ModelManager.verify(directory: staging, full: true) else {
            throw InstallError.smokeTestFailed("staged package failed verification")
        }

        // 4. Smoke inference before the package can become active.
        let test = smokeTest ?? defaultSmokeTest
        do {
            try test(staging)
        } catch {
            throw InstallError.smokeTestFailed(error.localizedDescription)
        }

        // 5. Activate atomically.
        let activated = try activate(staging: staging, root: root, manifest: manifest)
        completed = true
        progress?(.completed(activated))
        return activated
    }

    /// Installs an already-verified local directory (repo copy, offline install).
    @discardableResult
    public static func activateLocalPackage(
        at source: URL,
        root: URL = ModelManager.rootDirectory,
        smokeTest: ((URL) throws -> Void)? = nil
    ) throws -> URL {
        guard let manifest = ModelManager.manifest(of: source) else {
            throw InstallError.activationFailed("no manifest.json")
        }
        try ModelManager.validate(manifest)

        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)")
        try fm.copyItem(at: source, to: staging)
        _ = try? fm.removeItem(at: staging.appendingPathComponent(".pp-verified"))

        guard ModelManager.verify(directory: staging, full: true) else {
            try? fm.removeItem(at: staging)
            throw InstallError.smokeTestFailed("local package failed verification")
        }
        try (smokeTest ?? defaultSmokeTest)(staging)
        return try activate(staging: staging, root: root, manifest: manifest)
    }

    /// Moves staging into place, keeping the outgoing package for rollback.
    static func activate(staging: URL, root: URL, manifest: ModelManager.Manifest) throws -> URL {
        let fm = FileManager.default
        let active = root.appendingPathComponent("laya-mlx")
        let previous = root.appendingPathComponent("previous/laya-mlx")

        var state = ModelManager.loadState(root: root)
        let manifestChecksum = (try? Data(contentsOf: staging.appendingPathComponent("manifest.json")))
            .map { SHA256Hex($0) }

        if fm.fileExists(atPath: active.path) {
            try? fm.removeItem(at: previous)
            try fm.createDirectory(at: previous.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                try fm.moveItem(at: active, to: previous)
                state.previousManifestChecksum = state.manifestChecksum
            } catch {
                throw InstallError.activationFailed(error.localizedDescription)
            }
        }

        do {
            try fm.moveItem(at: staging, to: active)
        } catch {
            // Put the outgoing package back so the app is never left with nothing.
            if fm.fileExists(atPath: previous.path), !fm.fileExists(atPath: active.path) {
                try? fm.moveItem(at: previous, to: active)
            }
            throw InstallError.activationFailed(error.localizedDescription)
        }

        state.modelId = manifest.modelId
        state.packageName = manifest.packageName
        state.precision = manifest.precision
        state.manifestChecksum = manifestChecksum
        state.installedAt = Date()
        try ModelManager.saveState(state, root: root)
        return active
    }

    // MARK: Rollback

    /// Restores the previous verified package. The active package is discarded.
    @discardableResult
    public static func rollback(root: URL = ModelManager.rootDirectory) throws -> URL {
        let fm = FileManager.default
        let active = root.appendingPathComponent("laya-mlx")
        let previous = root.appendingPathComponent("previous/laya-mlx")

        guard fm.fileExists(atPath: previous.path) else { throw InstallError.nothingToRollBackTo }
        guard ModelManager.verify(directory: previous, full: true) else { throw InstallError.rollbackTargetUnverified }

        let broken = root.appendingPathComponent("broken-\(Int(Date().timeIntervalSince1970))")
        if fm.fileExists(atPath: active.path) {
            try? fm.removeItem(at: broken)
            try fm.moveItem(at: active, to: broken)
        }
        try fm.moveItem(at: previous, to: active)

        var state = ModelManager.loadState(root: root)
        state.manifestChecksum = state.previousManifestChecksum
        state.previousManifestChecksum = nil
        state.installedAt = Date()
        try ModelManager.saveState(state, root: root)
        // The superseded package is not kept; leaving it would double disk usage.
        try? fm.removeItem(at: broken)
        return active
    }

    /// True when a rollback target exists and still matches its checksums.
    public static func canRollBack(root: URL = ModelManager.rootDirectory) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent("previous/laya-mlx").path)
    }

    // MARK: Helpers

    public static func availableCapacity(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// Loads the staged package and runs one inference. Slow (loads ~840 MB) but only
    /// runs once per install, and it is the difference between "usable" and "verified
    /// bytes".
    public static func defaultSmokeTest(_ directory: URL) throws {
        let model = try LayaModel.load(from: directory)
        _ = model.evaluate(inputIds: [50281, 50284, 50282], markerPositions: [1], questionType: "noul")
    }
}

/// Hex SHA-256 of raw data.
func SHA256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
