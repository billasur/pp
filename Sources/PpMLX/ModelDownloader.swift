import Foundation

/// Provisions model packages on first run.
///
/// pp ships no weights. The app asks this type to fetch the package the user selected,
/// which either comes from a configured package host or from a local folder. A package
/// is staged, checksum-verified and smoke-tested before it replaces the active model,
/// and the outgoing package is retained so a bad release can be rolled back.
public actor ModelDownloader {
    public enum State: Equatable, Sendable {
        case idle
        case downloading(currentFile: String, fileIndex: Int, totalFiles: Int, bytesReceived: Int64, totalBytes: Int64)
        case verifying
        case completed(URL)
        case failed(String)
    }

    public enum DownloadError: LocalizedError, Equatable {
        case noSourceConfigured
        case noLocalPackage

        public var errorDescription: String? {
            switch self {
            case .noSourceConfigured:
                return "No model package source is configured. Set ModelPackageBaseURL to the host of your pp model package, or keep a verified package in models/laya-mlx for an offline install."
            case .noLocalPackage:
                return "No installable model package was found at that location."
            }
        }
    }

    /// Where the published pp model package lives, once you host one. Deliberately not
    /// pointed at the upstream Hugging Face checkpoint: that repo is a PyTorch Laya
    /// checkpoint, not an MLX pp package, and it has no manifest.
    public static let baseURLDefaultsKey = "ModelPackageBaseURL"
    public static let baseURLEnvironmentKey = "PP_MODEL_BASE_URL"

    private let session: URLSession
    private let root: URL
    private let environment: [String: String]
    private let defaults: UserDefaults

    public init(root: URL = ModelManager.rootDirectory,
                session: URLSession = .shared,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                defaults: UserDefaults = .standard) {
        self.root = root
        self.session = session
        self.environment = environment
        self.defaults = defaults
    }

    /// The configured package host, if any. Environment wins over user defaults so a
    /// test or a power user can override without touching the UI.
    public func configuredBaseURL() -> URL? {
        let raw = environment[Self.baseURLEnvironmentKey] ?? defaults.string(forKey: Self.baseURLDefaultsKey)
        guard let raw, let url = URL(string: raw) else { return nil }
        return url
    }

    /// Where the package should come from: a configured host, a local folder, or nothing.
    public func resolvedSource() -> (any ModelFileSource)? {
        if let base = configuredBaseURL() {
            if base.isFileURL { return LocalDirectorySource(directory: base) }
            return HTTPModelSource(baseURL: base)
        }
        let local = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("models/laya-mlx")
        if ModelManager.verify(directory: local, full: true) {
            return LocalDirectorySource(directory: local)
        }
        return nil
    }

    /// Downloads and activates the resolved package, keeping the previous one for rollback.
    @discardableResult
    public func download(
        progressHandler: @Sendable @escaping (State) -> Void = { _ in }
    ) async throws -> URL {
        guard let source = resolvedSource() else {
            progressHandler(.failed(DownloadError.noSourceConfigured.localizedDescription))
            throw DownloadError.noSourceConfigured
        }
        do {
            return try await ModelInstaller.install(from: source, root: root, progress: progressHandler)
        } catch {
            progressHandler(.failed(error.localizedDescription))
            throw error
        }
    }

    /// Installs a package from a local folder or a `file://` package the user picked.
    @discardableResult
    public func install(
        from location: URL,
        progressHandler: @Sendable @escaping (State) -> Void = { _ in }
    ) async throws -> URL {
        guard let source = LocalDirectorySource(url: location) else {
            throw DownloadError.noLocalPackage
        }
        do {
            return try await ModelInstaller.install(from: source, root: root, progress: progressHandler)
        } catch {
            progressHandler(.failed(error.localizedDescription))
            throw error
        }
    }

    /// Restores the previous verified package.
    @discardableResult
    public func rollback() throws -> URL {
        try ModelInstaller.rollback(root: root)
    }

    /// The active package directory, if the model is provisioned.
    public func activeModelDirectory() -> URL? {
        let active = root.appendingPathComponent("laya-mlx")
        return ModelManager.verify(directory: active, full: false) ? active : nil
    }
}
