import Foundation
import CryptoKit

/// Atomic model manager responsible for locating, verifying SHA-256 checksums, and provisioning local models.
public enum ModelManager {
    public struct ManifestFile: Codable, Equatable {
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

    public struct Manifest: Codable, Equatable {
        public let manifestVersion: String?
        public let modelId: String?
        public let packageName: String?
        public let precision: String?
        public let format: String?
        public let minPpVersion: String?
        public let files: [String: ManifestFile]

        enum CodingKeys: String, CodingKey {
            case manifestVersion = "manifest_version"
            case modelId = "model_id"
            case packageName = "package_name"
            case precision
            case format
            case minPpVersion = "min_pp_version"
            case files
        }

        public init(manifestVersion: String? = nil, modelId: String? = nil, packageName: String? = nil, precision: String? = nil, format: String? = nil, minPpVersion: String? = nil, files: [String: ManifestFile] = [:]) {
            self.manifestVersion = manifestVersion
            self.modelId = modelId
            self.packageName = packageName
            self.precision = precision
            self.format = format
            self.minPpVersion = minPpVersion
            self.files = files
        }
    }

    public static var defaultModelDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("pp/models/laya-mlx")
    }

    /// Computes streaming SHA-256 for a file to avoid loading massive safetensors into memory.
    public static func computeSHA256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        let chunkSize = 1024 * 1024 // 1 MB
        while true {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Verifies all files listed in manifest.json against their expected SHA-256 digests and file sizes.
    public static func verify(directory: URL) -> Bool {
        let manifestUrl = directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestUrl),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
            return false
        }

        guard !manifest.files.isEmpty else { return false }

        for (filename, expected) in manifest.files {
            let fileUrl = directory.appendingPathComponent(filename)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileUrl.path),
                  let fileSize = attrs[.size] as? Int64 else {
                return false
            }
            if fileSize != expected.sizeBytes {
                return false
            }
            guard let hash = try? computeSHA256(of: fileUrl) else {
                return false
            }
            if hash.lowercased() != expected.sha256.lowercased() {
                return false
            }
        }
        return true
    }

    /// Locates an existing verified model directory.
    public static func findVerifiedModel() -> URL? {
        let searchPaths = [
            defaultModelDirectory,
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("models/laya-mlx"),
            Bundle.main.resourceURL?.appendingPathComponent("models/laya-mlx")
        ].compactMap { $0 }

        for path in searchPaths {
            if verify(directory: path) {
                return path
            }
        }
        return nil
    }

    /// Ensures the Laya MLX model is available and verified in Application Support, copying from repo if present.
    @discardableResult
    public static func ensureModelAvailable() throws -> URL {
        let targetDir = defaultModelDirectory

        // 1. If already verified in Application Support
        if verify(directory: targetDir) {
            return targetDir
        }

        // 2. Check local workspace
        let localRepoDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("models/laya-mlx")
        if verify(directory: localRepoDir) {
            let parent = targetDir.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: targetDir.path) {
                try? FileManager.default.copyItem(at: localRepoDir, to: targetDir)
            }
            if verify(directory: targetDir) {
                return targetDir
            }
            return localRepoDir
        }

        throw NSError(domain: "pp.ModelManager", code: 404, userInfo: [NSLocalizedDescriptionKey: "No verified Laya model found in Application Support or local workspace."])
    }
}
