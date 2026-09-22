import CryptoKit
import XCTest
@testable import PpMLX

/// Setup-path tests: a package must be proven compatible and intact before it can
/// replace the working model, and a failure must never leave the app with nothing.
final class ModelInstallerTests: XCTestCase {

    private var root: URL!
    private var scratch: URL!

    override func setUpWithError() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pp-installer-\(UUID().uuidString)")
        root = base.appendingPathComponent("models")
        scratch = base.appendingPathComponent("scratch")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    // MARK: Fixtures

    private struct PackageSpec {
        var format = "safetensors"
        var architecture = "modernbert_laya"
        var precision = "float16"
        var minPpVersion = "0.1.0"
        var heads: [String]? = ["choice", "score", "noul"]
        var specialTokens: [String: Any]? = ["cls": 50281, "sep": 50282, "pad": 50283, "mask": 50284, "mask_token": "[MASK]"]
        var declaredSizeOverride: Int64? = nil
        var contents: [String: String] = [
            "model.safetensors": "weights",
            "config.json": "{\"architecture\":\"modernbert_laya\"}",
            "tokenizer.json": "{\"added_tokens\":[]}",
            "tokenizer_config.json": "{}"
        ]
        var corruptChecksum = false
    }

    @discardableResult
    private func makePackage(_ spec: PackageSpec, name: String = "package") throws -> URL {
        let dir = scratch.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var files: [String: [String: Any]] = [:]
        for (file, body) in spec.contents {
            let data = Data(body.utf8)
            try data.write(to: dir.appendingPathComponent(file))
            let hash = spec.corruptChecksum && file == "model.safetensors"
                ? String(repeating: "0", count: 64)
                : SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            files[file] = ["size_bytes": spec.declaredSizeOverride ?? Int64(data.count), "sha256": hash]
        }
        var manifest: [String: Any] = [
            "manifest_version": "2.0.0",
            "model_id": "test/model",
            "package_name": name,
            "format": spec.format,
            "architecture": spec.architecture,
            "precision": spec.precision,
            "min_pp_version": spec.minPpVersion,
            "files": files
        ]
        if let heads = spec.heads { manifest["heads"] = heads }
        if let tokens = spec.specialTokens { manifest["special_tokens"] = tokens }
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted])
            .write(to: dir.appendingPathComponent("manifest.json"))
        return dir
    }

    private let noSmoke: (URL) throws -> Void = { _ in }

    private func activeDirectory() -> URL { root.appendingPathComponent("laya-mlx") }

    // MARK: Validation

    func testRejectsWrongFormat() throws {
        let dir = try makePackage(PackageSpec(format: "gguf"))
        let manifest = try XCTUnwrap(ModelManager.manifest(of: dir))
        XCTAssertThrowsError(try ModelManager.validate(manifest)) { error in
            XCTAssertEqual(error as? ModelManager.ValidationError, .unsupportedFormat("gguf"))
        }
    }

    func testRejectsNonLayaArchitecture() throws {
        let dir = try makePackage(PackageSpec(architecture: "llama"))
        let manifest = try XCTUnwrap(ModelManager.manifest(of: dir))
        XCTAssertThrowsError(try ModelManager.validate(manifest)) { error in
            XCTAssertEqual(error as? ModelManager.ValidationError, .unsupportedArchitecture("llama"))
        }
    }

    func testRejectsMissingHeads() throws {
        let dir = try makePackage(PackageSpec(heads: ["choice"]))
        let manifest = try XCTUnwrap(ModelManager.manifest(of: dir))
        XCTAssertThrowsError(try ModelManager.validate(manifest)) { error in
            XCTAssertEqual(error as? ModelManager.ValidationError, .missingHeads(["score", "noul"]))
        }
    }

    func testRejectsMissingSpecialTokens() throws {
        let dir = try makePackage(PackageSpec(specialTokens: nil))
        let manifest = try XCTUnwrap(ModelManager.manifest(of: dir))
        XCTAssertThrowsError(try ModelManager.validate(manifest)) { error in
            XCTAssertEqual(error as? ModelManager.ValidationError, .missingSpecialTokens)
        }
    }

    func testRejectsPackageNeedingNewerApp() throws {
        let dir = try makePackage(PackageSpec(minPpVersion: "99.0.0"))
        let manifest = try XCTUnwrap(ModelManager.manifest(of: dir))
        XCTAssertThrowsError(try ModelManager.validate(manifest, appVersion: "0.1.0")) { error in
            XCTAssertEqual(error as? ModelManager.ValidationError, .requiresNewerApp(required: "99.0.0", current: "0.1.0"))
        }
    }

    func testAcceptsWellFormedManifest() throws {
        let dir = try makePackage(PackageSpec())
        let manifest = try XCTUnwrap(ModelManager.manifest(of: dir))
        XCTAssertNoThrow(try ModelManager.validate(manifest, appVersion: "0.1.0"))
    }

    // MARK: Install

    func testInstallActivatesVerifiedPackage() async throws {
        let dir = try makePackage(PackageSpec())
        let activated = try await ModelInstaller.install(
            from: LocalDirectorySource(directory: dir), root: root, appVersion: "0.1.0", smokeTest: noSmoke)
        XCTAssertEqual(activated.standardizedFileURL.path, activeDirectory().standardizedFileURL.path)
        XCTAssertTrue(ModelManager.verify(directory: activated, full: true))
        let state = ModelManager.loadState(root: root)
        XCTAssertEqual(state.packageName, "package")
    }

    func testInstallRefusesCorruptedChecksum() async throws {
        let dir = try makePackage(PackageSpec(corruptChecksum: true))
        do {
            _ = try await ModelInstaller.install(
                from: LocalDirectorySource(directory: dir), root: root, appVersion: "0.1.0", smokeTest: noSmoke)
            XCTFail("A package with a bad checksum must not install")
        } catch {
            XCTAssertTrue(String(describing: error).contains("checksum") || String(describing: error).contains("smoke"),
                          "unexpected error: \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: activeDirectory().path))
    }

    func testFailedInstallLeavesWorkingModelInPlace() async throws {
        let good = try makePackage(PackageSpec(), name: "good")
        _ = try await ModelInstaller.install(
            from: LocalDirectorySource(directory: good), root: root, appVersion: "0.1.0", smokeTest: noSmoke)
        XCTAssertTrue(ModelManager.verify(directory: activeDirectory(), full: true))

        let corrupt = try makePackage(PackageSpec(corruptChecksum: true), name: "bad")
        _ = try? await ModelInstaller.install(
            from: LocalDirectorySource(directory: corrupt), root: root, appVersion: "0.1.0", smokeTest: noSmoke)

        XCTAssertTrue(ModelManager.verify(directory: activeDirectory(), full: true),
                      "the previously working model must survive a failed update")
    }

    func testDiskCheckRunsBeforeWriting() async throws {
        let dir = try makePackage(PackageSpec(declaredSizeOverride: Int64.max / 4))
        do {
            _ = try await ModelInstaller.install(
                from: LocalDirectorySource(directory: dir), root: root, appVersion: "0.1.0", smokeTest: noSmoke)
            XCTFail("An impossibly large package must be refused")
        } catch let error as ModelInstaller.InstallError {
            guard case .insufficientDisk = error else {
                return XCTFail("expected insufficientDisk, got \(error)")
            }
        }
    }

    func testSmokeTestFailureBlocksActivation() async throws {
        let dir = try makePackage(PackageSpec())
        do {
            _ = try await ModelInstaller.install(
                from: LocalDirectorySource(directory: dir), root: root, appVersion: "0.1.0",
                smokeTest: { _ in throw ModelInstaller.InstallError.smokeTestFailed("model would not load") })
            XCTFail("A package that cannot run must not activate")
        } catch let error as ModelInstaller.InstallError {
            guard case .smokeTestFailed = error else {
                return XCTFail("expected smokeTestFailed, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: activeDirectory().path))
    }

    func testIncompatiblePackageNeverTouchesDisk() async throws {
        let dir = try makePackage(PackageSpec(heads: []))
        _ = try? await ModelInstaller.install(
            from: LocalDirectorySource(directory: dir), root: root, appVersion: "0.1.0", smokeTest: noSmoke)
        XCTAssertFalse(FileManager.default.fileExists(atPath: activeDirectory().path))
        XCTAssertFalse(ModelInstaller.canRollBack(root: root))
    }

    // MARK: Rollback

    func testRollbackRestoresPreviousPackage() async throws {
        let first = try makePackage(PackageSpec(contents: ["model.safetensors": "first", "config.json": "{}"]), name: "v1")
        _ = try await ModelInstaller.install(
            from: LocalDirectorySource(directory: first), root: root, appVersion: "0.1.0", smokeTest: noSmoke)
        let firstBytes = try Data(contentsOf: activeDirectory().appendingPathComponent("model.safetensors"))

        let second = try makePackage(PackageSpec(contents: ["model.safetensors": "second", "config.json": "{}"]), name: "v2")
        _ = try await ModelInstaller.install(
            from: LocalDirectorySource(directory: second), root: root, appVersion: "0.1.0", smokeTest: noSmoke)
        XCTAssertTrue(ModelInstaller.canRollBack(root: root))

        let restored = try ModelInstaller.rollback(root: root)
        let restoredBytes = try Data(contentsOf: restored.appendingPathComponent("model.safetensors"))
        XCTAssertEqual(restoredBytes, firstBytes, "rollback must restore the exact previous package")
        XCTAssertTrue(ModelManager.verify(directory: restored, full: true))
    }

    func testRollbackWithoutPreviousFails() {
        XCTAssertThrowsError(try ModelInstaller.rollback(root: root)) { error in
            XCTAssertEqual(error as? ModelInstaller.InstallError, .nothingToRollBackTo)
        }
    }

    // MARK: Verification caching

    func testFullVerificationStillCatchesTamperingAfterCaching() async throws {
        let dir = try makePackage(PackageSpec())
        _ = try await ModelInstaller.install(
            from: LocalDirectorySource(directory: dir), root: root, appVersion: "0.1.0", smokeTest: noSmoke)

        // Cached (launch-path) verification trusts the marker plus sizes.
        XCTAssertTrue(ModelManager.verify(directory: activeDirectory(), full: false))

        // Tamper with the same byte count: only a full hash may accept it.
        let target = activeDirectory().appendingPathComponent("model.safetensors")
        try Data("WEIGHT".utf8).write(to: target)
        XCTAssertFalse(ModelManager.verify(directory: activeDirectory(), full: true))
    }
}
