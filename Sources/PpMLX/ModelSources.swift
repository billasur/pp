import Foundation

/// A place a model package can be read from: a local directory, a mounted volume, or
/// a plain-HTTP host. Implementations never activate anything themselves; the
/// installer decides what becomes live.
/// A value-typed progress callback. Using a wrapper rather than a bare closure keeps
/// the protocol requirement and every witness spelled the same way.
public struct ProgressSink: Sendable {
    private let handler: @Sendable (Int64) -> Void
    public init(_ handler: @Sendable @escaping (Int64) -> Void) { self.handler = handler }
    public func callAsFunction(_ bytes: Int64) { handler(bytes) }
    public static let none = ProgressSink { _ in }
}

public protocol ModelFileSource: Sendable {
    /// The package's manifest bytes.
    func manifestData() async throws -> Data
    /// Fetches one file into `destination`, resuming when a partial file is present.
    /// `progress` receives total bytes written for this file.
    func fetch(_ file: String, expectedSize: Int64, to destination: URL,
               progress: ProgressSink) async throws
}

public struct ModelSourceError: LocalizedError, Equatable {
    public let message: String
    public var errorDescription: String? { message }

    public init(_ message: String) { self.message = message }

    public static func missing(_ file: String) -> ModelSourceError {
        ModelSourceError("The model package is missing \(file).")
    }
}

/// Reads a package from a directory or a `file://` URL. This is the offline install
/// path and the one the tests exercise.
public struct LocalDirectorySource: ModelFileSource {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public init?(url: URL) {
        guard url.isFileURL else { return nil }
        self.directory = url
    }

    public func manifestData() async throws -> Data {
        let manifest = directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifest) else {
            throw ModelSourceError.missing("manifest.json")
        }
        return data
    }

    public func fetch(_ file: String, expectedSize: Int64, to destination: URL,
                      progress: ProgressSink) async throws {
        let source = directory.appendingPathComponent(file)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw ModelSourceError.missing(file)
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(at: source, to: destination)
        progress(expectedSize)
    }
}

/// Moves a finished download into place inside the delegate callback, which is the
/// only point where the temporary file is guaranteed to exist. Appends when the
/// response was a 206 continuation of a partial file.
final class PackageDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let resumedFrom: Int64
    private let progress: ProgressSink
    private var continuation: CheckedContinuation<Int64, Error>?
    private var failure: Error?

    init(destination: URL, resumedFrom: Int64, progress: ProgressSink) {
        self.destination = destination
        self.resumedFrom = resumedFrom
        self.progress = progress
    }

    func attach(_ continuation: CheckedContinuation<Int64, Error>) {
        self.continuation = continuation
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        progress(resumedFrom + (totalBytesWritten - resumedFrom))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            let fm = FileManager.default
            if resumedFrom > 0 {
                let source = try FileHandle(forReadingFrom: location)
                defer { try? source.close() }
                if !fm.fileExists(atPath: destination.path) {
                    fm.createFile(atPath: destination.path, contents: nil)
                }
                let target = try FileHandle(forWritingTo: destination)
                defer { try? target.close() }
                try target.seekToEnd()
                while let chunk = try source.read(upToCount: 1 << 20), !chunk.isEmpty {
                    try target.write(contentsOf: chunk)
                }
            } else {
                if fm.fileExists(atPath: destination.path) {
                    try fm.removeItem(at: destination)
                }
                try fm.moveItem(at: location, to: destination)
            }
        } catch {
            failure = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path)
        let size = (attributes?[.size] as? Int64) ?? 0
        if let error {
            continuation?.resume(throwing: error)
        } else if let failure {
            continuation?.resume(throwing: failure)
        } else {
            continuation?.resume(returning: size)
        }
        continuation = nil
    }
}

/// Plain-HTTP source with byte-range resume. No cloud SDK, no auth, no redirects to
/// anything but the configured host.
public actor HTTPModelSource: ModelFileSource {
    public let baseURL: URL

    /// Where the package lives, when the link names a revision rather than a folder.
    private let revisionOverride: String?

    public init(baseURL: URL, revision: String? = nil) {
        self.baseURL = baseURL
        self.revisionOverride = revision
    }

    /// Whether this link is a Hugging Face repository rather than a plain file host.
    public static func isHuggingFace(_ url: URL) -> Bool {
        (url.host ?? "").lowercased().hasSuffix("huggingface.co") && repo(in: url) != nil
    }

    /// Splits `/<owner>/<repo>`, `/<owner>/<repo>/tree/<rev>` and the equivalent
    /// `/blob/` and `/resolve/` forms into the parts a file URL needs.
    public static func repo(in url: URL) -> (owner: String, name: String, revision: String)? {
        var parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        var revision = "main"
        if let marker = parts.firstIndex(where: { ["tree", "blob", "resolve"].contains($0) }),
           parts.count > marker + 1 {
            revision = parts[marker + 1]
            parts = Array(parts[..<marker])
        }
        guard parts.count >= 2 else { return nil }
        return (parts[0], parts[1], revision)
    }

    /// The URL of one file inside the package.
    ///
    /// A plain host serves the package folder directly: `base/<file>`. A Hugging Face link
    /// is a repository link, and every file in it lives under `/resolve/<revision>/`, so
    /// pasting the repository URL a person sees in their browser is enough.
    public func fileURL(_ file: String) -> URL {
        guard let repo = Self.repo(in: baseURL), Self.isHuggingFace(baseURL) else {
            return baseURL.appendingPathComponent(file)
        }
        let revision = revisionOverride ?? repo.revision
        var components = URLComponents()
        components.scheme = baseURL.scheme ?? "https"
        components.host = baseURL.host
        components.path = "/\(repo.owner)/\(repo.name)/resolve/\(revision)/\(file)"
        return components.url ?? baseURL.appendingPathComponent(file)
    }

    public func manifestData() async throws -> Data {
        var request = URLRequest(url: fileURL("manifest.json"))
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        do {
            try Self.checkStatus(response, file: "manifest.json")
        } catch {
            // The likeliest mistake by far: a Hugging Face link to the original PyTorch
            // Laya checkpoint. Say what is wrong and what to do instead, rather than
            // reporting "HTTP 404".
            if Self.isHuggingFace(baseURL), (response as? HTTPURLResponse)?.statusCode == 404 {
                throw ModelSourceError("That Hugging Face repository has no manifest.json, so it is not a pp model package. The upstream Laya repository is a PyTorch checkpoint; pp needs the MLX conversion (tools/convert_laya.py) published with a manifest.json. Link a repository that already contains one, choose a local folder instead, or set a decision service URL in Settings to use your own model.")
            }
            throw error
        }
        return data
    }

    public func fetch(_ file: String, expectedSize: Int64, to destination: URL,
                      progress: ProgressSink) async throws {
        let fm = FileManager.default
        let attributes = try? fm.attributesOfItem(atPath: destination.path)
        let existing = (attributes?[.size] as? Int64) ?? 0
        let resumedFrom = min(max(existing, 0), expectedSize)
        if resumedFrom >= expectedSize, expectedSize > 0 {
            progress(expectedSize)
            return
        }

        var request = URLRequest(url: fileURL(file))
        request.timeoutInterval = 120
        if resumedFrom > 0 {
            request.setValue("bytes=\(resumedFrom)-", forHTTPHeaderField: "Range")
        }

        let delegate = PackageDownloadDelegate(destination: destination, resumedFrom: resumedFrom, progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let finalSize: Int64 = try await withCheckedThrowingContinuation { continuation in
            delegate.attach(continuation)
            let task = session.downloadTask(with: request)
            task.resume()
        }
        progress(finalSize)
    }

    private static func checkStatus(_ response: URLResponse, file: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ModelSourceError("No response for \(file).")
        }
        guard (200...299).contains(http.statusCode) else {
            throw ModelSourceError("Server returned HTTP \(http.statusCode) for \(file).")
        }
    }
}
