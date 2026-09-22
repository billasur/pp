import Foundation

/// Asynchronous downloader for provisioning local MLX model weights from Hugging Face with checksum verification and atomic staging.
public actor ModelDownloader {
    public enum State: Equatable {
        case idle
        case downloading(currentFile: String, fileIndex: Int, totalFiles: Int, bytesReceived: Int64, totalBytes: Int64)
        case verifying
        case completed(URL)
        case failed(String)
    }

    public static let defaultBaseURL = URL(string: "https://huggingface.co/convaiinnovations/laya/resolve/main")!

    private let session: URLSession
    private let baseURL: URL
    private var downloadTask: Task<URL, Error>?

    public init(baseURL: URL = defaultBaseURL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    /// Downloads the Laya MLX model to Application Support with atomic staging and validation.
    public func download(
        progressHandler: @Sendable @escaping (State) -> Void = { _ in }
    ) async throws -> URL {
        let targetDir = ModelManager.defaultModelDirectory
        let parentDir = targetDir.deletingLastPathComponent()
        let stagingDir = parentDir.appendingPathComponent(".staging_\(UUID().uuidString)")

        let fm = FileManager.default
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        defer {
            if fm.fileExists(atPath: stagingDir.path) {
                try? fm.removeItem(at: stagingDir)
            }
        }

        // 1. Download manifest.json
        let manifestUrl = baseURL.appendingPathComponent("manifest.json")
        let (manifestData, _) = try await session.data(from: manifestUrl)
        let manifest = try JSONDecoder().decode(ModelManager.Manifest.self, from: manifestData)
        try manifestData.write(to: stagingDir.appendingPathComponent("manifest.json"))

        // 2. Download all files in manifest
        let fileList = Array(manifest.files.keys.sorted())
        let totalBytes = manifest.files.values.reduce(Int64(0)) { $0 + $1.sizeBytes }
        var bytesAccumulated: Int64 = 0

        for (index, filename) in fileList.enumerated() {
            let fileExpected = manifest.files[filename]!
            let fileRemoteUrl = baseURL.appendingPathComponent(filename)
            let fileDestination = stagingDir.appendingPathComponent(filename)

            progressHandler(.downloading(
                currentFile: filename,
                fileIndex: index + 1,
                totalFiles: fileList.count,
                bytesReceived: bytesAccumulated,
                totalBytes: totalBytes
            ))

            let (tempUrl, response) = try await session.download(from: fileRemoteUrl)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw NSError(domain: "pp.ModelDownloader", code: 500, userInfo: [NSLocalizedDescriptionKey: "Failed to download \(filename): server error"])
            }

            if fm.fileExists(atPath: fileDestination.path) {
                try fm.removeItem(at: fileDestination)
            }
            try fm.moveItem(at: tempUrl, to: fileDestination)

            bytesAccumulated += fileExpected.sizeBytes
            progressHandler(.downloading(
                currentFile: filename,
                fileIndex: index + 1,
                totalFiles: fileList.count,
                bytesReceived: bytesAccumulated,
                totalBytes: totalBytes
            ))
        }

        // 3. Verify staging directory
        progressHandler(.verifying)
        guard ModelManager.verify(directory: stagingDir) else {
            throw NSError(domain: "pp.ModelDownloader", code: 422, userInfo: [NSLocalizedDescriptionKey: "Downloaded model files failed SHA-256 integrity verification."])
        }

        // 4. Atomic activation
        if fm.fileExists(atPath: targetDir.path) {
            try fm.removeItem(at: targetDir)
        }
        try fm.moveItem(at: stagingDir, to: targetDir)

        progressHandler(.completed(targetDir))
        return targetDir
    }
}
