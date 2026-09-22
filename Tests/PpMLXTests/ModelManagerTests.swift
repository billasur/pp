import XCTest
import Foundation
@testable import PpMLX

final class ModelManagerTests: XCTestCase {
    func testManifestDecoding() throws {
        let manifestPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("models/laya-mlx/manifest.json")
        guard FileManager.default.fileExists(atPath: manifestPath.path) else {
            throw XCTSkip("models/laya-mlx/manifest.json not present in workspace")
        }

        let data = try Data(contentsOf: manifestPath)
        let manifest = try JSONDecoder().decode(ModelManager.Manifest.self, from: data)

        XCTAssertEqual(manifest.modelId, "convaiinnovations/laya")
        XCTAssertEqual(manifest.packageName, "laya-421m-mlx")
        XCTAssertTrue(manifest.files.keys.contains("model.safetensors"))
        XCTAssertTrue(manifest.files.keys.contains("config.json"))
        XCTAssertTrue(manifest.files.keys.contains("tokenizer.json"))
        XCTAssertEqual(manifest.files["config.json"]?.sha256, "d715c2f08bb168c073be17017450c186f9a2e333177e7cb9be35fd2e95f1935c")
    }

    func testStreamingSHA256() throws {
        let configPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("models/laya-mlx/config.json")
        guard FileManager.default.fileExists(atPath: configPath.path) else {
            throw XCTSkip("config.json not present")
        }

        let hash = try ModelManager.computeSHA256(of: configPath)
        XCTAssertEqual(hash.lowercased(), "d715c2f08bb168c073be17017450c186f9a2e333177e7cb9be35fd2e95f1935c")
    }

    func testModelDirectoryVerification() {
        let modelDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("models/laya-mlx")
        guard FileManager.default.fileExists(atPath: modelDir.appendingPathComponent("model.safetensors").path) else {
            return
        }

        let isVerified = ModelManager.verify(directory: modelDir)
        XCTAssertTrue(isVerified, "models/laya-mlx directory must verify cleanly against manifest.json")
    }
}
