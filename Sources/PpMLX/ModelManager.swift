import CryptoKit
import Foundation
import PpCore

/// Locates, validates and verifies local decision-model packages.
///
/// A package is a directory containing `manifest.json` plus every file the manifest
/// lists. Nothing is usable until every listed file matches its recorded size and
/// SHA-256. Verification is cached in a `.pp-verified` marker so launch does a cheap
/// size check and only a fresh install pays for hashing 840 MB.
public enum ModelManager {

    // MARK: Manifest

    public struct ManifestFile: Codable, Equatable, Sendable {
        public let sizeBytes: Int64
        public let sha256: String

        enum CodingKeys: String, CodingKey {
            case sizeBytes = "size_bytes"
            case sha256
        }

        public init(sizeBytes: Int64, sha256: String) {
            self.sizeBytes = sizeBytes
            self.sha256 = sha256
        }
    }

    public struct SpecialTokens: Codable, Equatable, Sendable {
        public let cls: Int?
        public let sep: Int?
        public let pad: Int?
        public let mask: Int?
        public let unk: Int?
        public let maskToken: String?

        enum CodingKeys: String, CodingKey {
            case cls, sep, pad, mask, unk
            case maskToken = "mask_token"
        }

        public init(cls: Int?, sep: Int?, pad: Int?, mask: Int?, unk: Int?, maskToken: String?) {
            self.cls = cls; self.sep = sep; self.pad = pad; self.mask = mask; self.unk = unk; self.maskToken = maskToken
        }
    }

    public struct Manifest: Codable, Equatable, Sendable {
        public let manifestVersion: String?
        public let modelId: String?
        public let packageName: String?
        public let architecture: String?
        public let precision: String?
        public let format: String?
        public let minPpVersion: String?
        public let maxPositionEmbeddings: Int?
        public let hiddenSize: Int?
        public let numHiddenLayers: Int?
        public let specialTokens: SpecialTokens?
        public let heads: [String]?
        public let files: [String: ManifestFile]

        enum CodingKeys: String, CodingKey {
            case manifestVersion = "manifest_version"
            case modelId = "model_id"
            case packageName = "package_name"
            case architecture
            case precision
            case format
            case minPpVersion = "min_pp_version"
            case maxPositionEmbeddings = "max_position_embeddings"
            case hiddenSize = "hidden_size"
            case numHiddenLayers = "num_hidden_layers"
            case specialTokens = "special_tokens"
            case heads
            case files
        }

        public init(manifestVersion: String? = nil, modelId: String? = nil, packageName: String? = nil,
                    architecture: String? = nil, precision: String? = nil, format: String? = nil,
                    minPpVersion: String? = nil, maxPositionEmbeddings: Int? = nil, hiddenSize: Int? = nil,
                    numHiddenLayers: Int? = nil, specialTokens: SpecialTokens? = nil, heads: [String]? = nil,
                    files: [String: ManifestFile] = [:]) {
            self.manifestVersion = manifestVersion; self.modelId = modelId; self.packageName = packageName
            self.architecture = architecture; self.precision = precision; self.format = format
            self.minPpVersion = minPpVersion; self.maxPositionEmbeddings = maxPositionEmbeddings
            self.hiddenSize = hiddenSize; self.numHiddenLayers = numHiddenLayers
            self.specialTokens = specialTokens; self.heads = heads; self.files = files
        }

        /// Saturating sum: a hostile or corrupt manifest must not overflow us into a
        /// negative size that bypasses the disk-space check.
        public var totalBytes: Int64 {
            files.values.reduce(0) { partial, file in
                let (sum, overflow) = partial.addingReportingOverflow(file.sizeBytes)
                return overflow ? Int64.max : sum
            }
        }
    }

    // MARK: Validation

    public enum ValidationError: LocalizedError, Equatable {
        case unreadableManifest
        case emptyFileList
        case unsupportedFormat(String?)
        case unsupportedArchitecture(String?)
        case unsupportedPrecision(String?)
        case missingSpecialTokens
        case missingHeads([String])
        case requiresNewerApp(required: String, current: String)

        public var errorDescription: String? {
            switch self {
            case .unreadableManifest:
                return "The model package has no readable manifest.json. It cannot be verified, so it was not activated."
            case .emptyFileList:
                return "The model package manifest lists no files."
            case .unsupportedFormat(let format):
                return "This package is in '\(format ?? "unknown")' format. pp loads MLX safetensors."
            case .unsupportedArchitecture(let architecture):
                return "This package is architecture '\(architecture ?? "unknown")'. pp needs a ModernBERT + Laya decision head."
            case .unsupportedPrecision(let precision):
                return "Precision '\(precision ?? "unknown")' is not supported. Use float16 or 8-bit."
            case .missingSpecialTokens:
                return "The package does not declare its special-token ids, so the Laya sequence contract cannot be guaranteed."
            case .missingHeads(let heads):
                return "The package is missing required decision heads: \(heads.joined(separator: ", "))."
            case .requiresNewerApp(let required, let current):
                return "This package needs pp \(required) or newer. You are running \(current)."
            }
        }
    }

    public static let requiredHeads = ["choice", "score", "noul"]
    public static let supportedPrecisions = ["float16", "fp16", "8bit", "int8"]
    public static let productName = "laya-421m-mlx"

    /// The app version used for `min_pp_version` checks. Falls back for tests.
    public static var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.1.0"
    }

    /// Validates a manifest against what pp can actually load. Run before any download
    /// or activation, so an incompatible package is rejected while it is still inert.
    public static func validate(_ manifest: Manifest, appVersion: String = ModelManager.currentVersion) throws {
        guard !manifest.files.isEmpty else { throw ValidationError.emptyFileList }
        let format = manifest.format?.lowercased()
        if let format, format != "safetensors", format != "mlx" {
            throw ValidationError.unsupportedFormat(manifest.format)
        }
        if let architecture = manifest.architecture?.lowercased(),
           !architecture.contains("modernbert") || !architecture.contains("laya") {
            throw ValidationError.unsupportedArchitecture(manifest.architecture)
        }
        if let precision = manifest.precision?.lowercased(), !supportedPrecisions.contains(precision) {
            throw ValidationError.unsupportedPrecision(manifest.precision)
        }
        if let tokens = manifest.specialTokens {
            if tokens.cls == nil || tokens.sep == nil || tokens.pad == nil || tokens.mask == nil {
                throw ValidationError.missingSpecialTokens
            }
        } else {
            throw ValidationError.missingSpecialTokens
        }
        if let heads = manifest.heads {
            let missing = requiredHeads.filter { !heads.contains($0) }
            if !missing.isEmpty { throw ValidationError.missingHeads(missing) }
        } else {
            throw ValidationError.missingHeads(requiredHeads)
        }
        if let required = manifest.minPpVersion, compareVersions(appVersion, required) < 0 {
            throw ValidationError.requiresNewerApp(required: required, current: appVersion)
        }
    }

    /// Version comparison lives in PpCore so the update policy can use it too.
    public static func compareVersions(_ lhs: String, _ rhs: String) -> Int {
        PpVersion.compare(lhs, rhs)
    }

    // MARK: Locations

    public static var rootDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("pp/models")
    }

    /// Canonical active package location. Unchanged from earlier releases.
    public static var defaultModelDirectory: URL {
        rootDirectory.appendingPathComponent("laya-mlx")
    }

    /// Where the last known-good package is kept for rollback.
    public static var previousModelDirectory: URL {
        rootDirectory.appendingPathComponent("previous/laya-mlx")
    }

    public static var stateFile: URL { rootDirectory.appendingPathComponent("state.json") }

    public struct InstallState: Codable, Equatable, Sendable {
        public var modelId: String?
        public var packageName: String?
        public var precision: String?
        public var manifestChecksum: String?
        public var installedAt: Date?
        public var previousManifestChecksum: String?

        public init(modelId: String? = nil, packageName: String? = nil, precision: String? = nil,
                    manifestChecksum: String? = nil, installedAt: Date? = nil, previousManifestChecksum: String? = nil) {
            self.modelId = modelId; self.packageName = packageName; self.precision = precision
            self.manifestChecksum = manifestChecksum; self.installedAt = installedAt
            self.previousManifestChecksum = previousManifestChecksum
        }
    }

    /// Install state goes through the shared pp JSON convention, so `installedAt` survives
    /// a save/load cycle unchanged and a rollback can trust what it reads back.
    private static var stateDecoder: JSONDecoder { PpJSON.decoder() }

    private static var stateEncoder: JSONEncoder { PpJSON.encoder(pretty: true) }

    public static func loadState(root: URL = ModelManager.rootDirectory) -> InstallState {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("state.json")),
              let state = try? stateDecoder.decode(InstallState.self, from: data) else {
            return InstallState()
        }
        return state
    }

    public static func saveState(_ state: InstallState, root: URL = ModelManager.rootDirectory) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try stateEncoder.encode(state)
        let target = root.appendingPathComponent("state.json")
        let temporary = root.appendingPathComponent(".state-\(UUID().uuidString).json")
        try data.write(to: temporary)
        if fm.fileExists(atPath: target.path) {
            _ = try fm.replaceItemAt(target, withItemAt: temporary)
        } else {
            try fm.moveItem(at: temporary, to: target)
        }
    }

    // MARK: Verification

    public static func manifest(of directory: URL) -> Manifest? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")) else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }

    /// Streaming SHA-256 so large weights are never loaded into memory.
    public static func computeSHA256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private struct VerifiedMarker: Codable, Equatable {
        let manifestChecksum: String
        let files: [String: ManifestFile]
    }

    private static var markerURL: (URL) -> URL {
        { $0.appendingPathComponent(".pp-verified") }
    }

    /// Verifies a package. `full: true` hashes every file; `full: false` trusts an
    /// existing marker and only re-checks sizes, which is what app launch uses.
    public static func verify(directory: URL, full: Bool = true) -> Bool {
        guard let manifest = manifest(of: directory), !manifest.files.isEmpty else { return false }
        guard let manifestData = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")) else { return false }
        let manifestChecksum = SHA256.hash(data: manifestData).map { String(format: "%02x", $0) }.joined()

        if !full,
           let markerData = try? Data(contentsOf: markerURL(directory)),
           let marker = try? JSONDecoder().decode(VerifiedMarker.self, from: markerData),
           marker.manifestChecksum == manifestChecksum,
           marker.files == manifest.files,
           sizesMatch(manifest: manifest, directory: directory) {
            return true
        }

        guard hashesMatch(manifest: manifest, directory: directory) else {
            try? FileManager.default.removeItem(at: markerURL(directory))
            return false
        }
        let marker = VerifiedMarker(manifestChecksum: manifestChecksum, files: manifest.files)
        if let data = try? JSONEncoder().encode(marker) {
            try? data.write(to: markerURL(directory))
        }
        return true
    }

    private static func sizesMatch(manifest: Manifest, directory: URL) -> Bool {
        for (name, expected) in manifest.files {
            let attributes = try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path)
            guard let size = attributes?[.size] as? Int64, size == expected.sizeBytes else { return false }
        }
        return true
    }

    private static func hashesMatch(manifest: Manifest, directory: URL) -> Bool {
        for (name, expected) in manifest.files {
            let url = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path),
                  let hash = try? computeSHA256(of: url),
                  hash.lowercased() == expected.sha256.lowercased() else { return false }
        }
        return true
    }

    // MARK: Discovery

    /// Locates an existing verified active package. Cheap check first, then a full one.
    public static func findVerifiedModel() -> URL? {
        let candidates = [
            defaultModelDirectory,
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("models/laya-mlx"),
            Bundle.main.resourceURL?.appendingPathComponent("models/laya-mlx")
        ].compactMap { $0 }

        for path in candidates where verify(directory: path, full: false) {
            return path
        }
        for path in candidates where verify(directory: path, full: true) {
            return path
        }
        return nil
    }

    /// Ensures a model is available in Application Support, copying from the repo when present.
    @discardableResult
    public static func ensureModelAvailable() throws -> URL {
        if verify(directory: defaultModelDirectory) { return defaultModelDirectory }

        let localRepoDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("models/laya-mlx")
        if verify(directory: localRepoDir) {
            let installed = try ModelInstaller.activateLocalPackage(at: localRepoDir)
            return installed
        }
        throw NSError(domain: "pp.ModelManager", code: 404,
                      userInfo: [NSLocalizedDescriptionKey: "No verified Laya model found in Application Support or local workspace."])
    }
}
