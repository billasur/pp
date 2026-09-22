import CryptoKit
import XCTest
import PpCore
@testable import PpMLX

final class BYOMValidatorTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pp-byom-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private var realPackage: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("models/laya-mlx")
    }

    /// A small package containing only the tokenizer files, so the contract checks can
    /// run without copying 840 MB of weights.
    private func makeTokenizerOnlyPackage() throws -> URL {
        let fm = FileManager.default
        for name in ["config.json", "tokenizer.json", "tokenizer_config.json"] {
            try fm.copyItem(at: realPackage.appendingPathComponent(name), to: scratch.appendingPathComponent(name))
        }
        let manifest = ModelManager.manifest(of: realPackage)!
        var files: [String: ModelManager.ManifestFile] = [:]
        for name in ["config.json", "tokenizer.json", "tokenizer_config.json"] {
            let data = try Data(contentsOf: scratch.appendingPathComponent(name))
            files[name] = ModelManager.ManifestFile(
                sizeBytes: Int64(data.count),
                sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        }
        let rebuilt = ModelManager.Manifest(
            manifestVersion: manifest.manifestVersion, modelId: manifest.modelId, packageName: manifest.packageName,
            architecture: manifest.architecture, precision: manifest.precision, format: manifest.format,
            minPpVersion: manifest.minPpVersion, maxPositionEmbeddings: manifest.maxPositionEmbeddings,
            hiddenSize: manifest.hiddenSize, numHiddenLayers: manifest.numHiddenLayers,
            specialTokens: manifest.specialTokens, heads: manifest.heads, files: files)
        try JSONEncoder().encode(rebuilt).write(to: scratch.appendingPathComponent("manifest.json"))
        return scratch
    }

    func testAFullLocalPackagePassesEveryShallowCheck() throws {
        guard FileManager.default.fileExists(atPath: realPackage.path) else {
            throw XCTSkip("models/laya-mlx not present")
        }
        let report = try BYOMPackageValidator.validate(directory: realPackage, appVersion: "0.1.0")
        XCTAssertTrue(report.passed, "failures: \(report.failures)")
        XCTAssertTrue(report.checks.contains { $0.name == "special-tokens" && $0.passed })
        XCTAssertTrue(report.checks.contains { $0.name == "sequence" && $0.passed })
        XCTAssertTrue(report.checks.contains { $0.name == "safety-gate" && $0.passed })
    }

    func testTokenizerOnlyPackagePassesTheContractChecks() throws {
        let report = try BYOMPackageValidator.validate(directory: try makeTokenizerOnlyPackage(), appVersion: "0.1.0")
        XCTAssertTrue(report.passed, "failures: \(report.failures)")
    }

    func testMismatchedSpecialTokenIdsAreRejected() throws {
        let directory = try makeTokenizerOnlyPackage()
        var manifest = ModelManager.manifest(of: directory)!
        manifest = ModelManager.Manifest(
            manifestVersion: manifest.manifestVersion, modelId: manifest.modelId, packageName: manifest.packageName,
            architecture: manifest.architecture, precision: manifest.precision, format: manifest.format,
            minPpVersion: manifest.minPpVersion, maxPositionEmbeddings: manifest.maxPositionEmbeddings,
            hiddenSize: manifest.hiddenSize, numHiddenLayers: manifest.numHiddenLayers,
            specialTokens: ModelManager.SpecialTokens(cls: 5, sep: 6, pad: 7, mask: 8, unk: 9, maskToken: "[MASK]"),
            heads: manifest.heads, files: manifest.files)
        try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("manifest.json"))

        let report = try BYOMPackageValidator.validate(directory: directory, appVersion: "0.1.0")
        XCTAssertFalse(report.passed)
        let check = try XCTUnwrap(report.checks.first { $0.name == "special-tokens" })
        XCTAssertFalse(check.passed)
        XCTAssertTrue(check.detail.contains("wrong marker"), "detail should explain the consequence: \(check.detail)")
    }

    func testAChecksumMismatchIsCaught() throws {
        let directory = try makeTokenizerOnlyPackage()
        try Data("tampered".utf8).write(to: directory.appendingPathComponent("config.json"))
        let report = try BYOMPackageValidator.validate(directory: directory, appVersion: "0.1.0")
        XCTAssertFalse(report.passed)
        XCTAssertFalse(try XCTUnwrap(report.checks.first { $0.name == "checksums" }).passed)
    }

    func testAFailingDeepSmokeTestBlocksThePackage() throws {
        let directory = try makeTokenizerOnlyPackage()
        let report = try BYOMPackageValidator.validate(directory: directory, appVersion: "0.1.0",
                                                      deepSmokeTest: { _ in throw LoRAAdapterError.corruptedWeights })
        XCTAssertFalse(report.passed)
        XCTAssertFalse(try XCTUnwrap(report.checks.first { $0.name == "heads" }).passed)
    }

    func testMissingManifestIsASingleClearFailure() throws {
        let report = try BYOMPackageValidator.validate(directory: scratch, appVersion: "0.1.0")
        XCTAssertFalse(report.passed)
        XCTAssertEqual(report.checks.count, 1)
        XCTAssertEqual(report.checks[0].name, "manifest")
    }
}

final class TrainingTraceTests: XCTestCase {

    private var question: LayaQuestion {
        LayaQuestion(id: "target", type: "choice",
                     instructions: "Which control is the step talking about?",
                     options: ["Open: open the notes", "Close: close the window"],
                     optionIDs: ["e1", "e2"])
    }

    func testOnlySuccessfulInteractionsBecomeExamples() {
        XCTAssertNil(TrainingTraceBuilder.example(question: question, selectedIndex: 0, succeeded: false,
                                                  modelVersion: "1", structureFingerprint: "fp"))
        XCTAssertNotNil(TrainingTraceBuilder.example(question: question, selectedIndex: 0, succeeded: true,
                                                     modelVersion: "1", structureFingerprint: "fp"))
    }

    func testAnOutOfRangeChoiceIsRefused() {
        XCTAssertNil(TrainingTraceBuilder.example(question: question, selectedIndex: 9, succeeded: true,
                                                  modelVersion: "1", structureFingerprint: "fp"))
    }

    func testSensitiveOptionsNeverBecomeExamples() {
        let sensitive = LayaQuestion(id: "target", type: "choice", instructions: "Fill the form",
                                     options: ["Password field: enter your password", "Email: your address"],
                                     optionIDs: ["p", "e"])
        XCTAssertNil(TrainingTraceBuilder.example(question: sensitive, selectedIndex: 0, succeeded: true,
                                                  modelVersion: "1", structureFingerprint: "fp"))

        let code = LayaQuestion(id: "target", type: "choice", instructions: "Enter the code",
                                options: ["Code field: 483920", "Cancel"], optionIDs: ["c", "x"])
        XCTAssertNil(TrainingTraceBuilder.example(question: code, selectedIndex: 0, succeeded: true,
                                                  modelVersion: "1", structureFingerprint: "fp"))
    }

    func testStaleSchemaIsRejectedOnImport() throws {
        let example = TrainingExample(schemaVersion: 99, createdAt: Date(), questionType: "choice",
                                      instructions: "i", options: ["a", "b"], selectedIndex: 0,
                                      succeeded: true, modelVersion: "1", structureFingerprint: "fp",
                                      provenance: "interactive")
        XCTAssertThrowsError(try TrainingTraceBuilder.validate(example)) { error in
            XCTAssertEqual(error as? TraceRejection, .staleSchema(99))
        }
    }

    func testCorpusRoundTripsAndRejectsBadExamples() throws {
        let corpus = TrainingCorpus()
        let good = try XCTUnwrap(TrainingTraceBuilder.example(question: question, selectedIndex: 1, succeeded: true,
                                                              modelVersion: "1", structureFingerprint: "fp"))
        XCTAssertTrue(corpus.add(good))

        let bad = TrainingExample(createdAt: Date(), questionType: "choice", instructions: "i",
                                  options: ["Password", "Cancel"], selectedIndex: 0, succeeded: true,
                                  modelVersion: "1", structureFingerprint: "fp", provenance: "interactive")
        XCTAssertFalse(corpus.add(bad), "a sensitive example must not be storable at all")
        XCTAssertEqual(corpus.count, 1)

        let exported = try corpus.export()
        let restored = TrainingCorpus()
        try restored.importCorpus(exported)
        XCTAssertEqual(restored.all, corpus.all, "an export must re-import to exactly the same examples")
    }
}

final class AdapterPromotionTests: XCTestCase {

    private func manifest() -> ModelManager.Manifest {
        ModelManager.Manifest(manifestVersion: "2.0.0", modelId: "convaiinnovations/laya",
                              packageName: "laya-421m-mlx", architecture: "modernbert_laya",
                              precision: "float16", format: "safetensors", minPpVersion: "0.1.0",
                              specialTokens: ModelManager.SpecialTokens(cls: 50281, sep: 50282, pad: 50283, mask: 50284, unk: 50280, maskToken: "[MASK]"),
                              heads: ["choice", "score", "noul"], files: ["config.json": .init(sizeBytes: 1, sha256: "x")])
    }

    private func adapter(baseChecksum: String = "base-checksum", tokenizer: String = "tok-checksum",
                         heads: [String] = ["choice", "score", "noul"], schema: Int = 1,
                         weightsHash: String = "") -> LoRAAdapterPackage {
        LoRAAdapterPackage(id: "a1", baseModelID: "convaiinnovations/laya", baseModelManifestChecksum: baseChecksum,
                           tokenizerChecksum: tokenizer, trainingSchemaVersion: schema, heads: heads,
                           weightsSHA256: weightsHash, exampleCount: 40, createdAt: Date())
    }

    private func report(replay: Double, safety: Double = 1.0, blocking: Int = 0, latency: Double = 300) -> EvaluationReport {
        EvaluationReport(replayAccuracy: replay, safetyPassRate: safety, blockingSafetyFailures: blocking, latencyP50Ms: latency)
    }

    func testGatePromotesOnlyWhenAccuracyAndSafetyBothHold() {
        let baseline = report(replay: 0.90)
        XCTAssertTrue(PromotionGate.decide(candidate: report(replay: 0.95), baseline: baseline).isPromoted)
        XCTAssertFalse(PromotionGate.decide(candidate: report(replay: 0.90), baseline: baseline).isPromoted)
    }

    func testAccuracyGainNeverOutweighsASafetyRegression() {
        let baseline = report(replay: 0.90)
        let risky = report(replay: 0.99, safety: 1.0, blocking: 1)
        guard case .reject(let reason) = PromotionGate.decide(candidate: risky, baseline: baseline) else {
            return XCTFail("a blocking safety regression must be rejected")
        }
        XCTAssertTrue(reason.contains("safety"))

        let loose = report(replay: 0.99, safety: 0.98, blocking: 0)
        XCTAssertFalse(PromotionGate.decide(candidate: loose, baseline: baseline).isPromoted)
    }

    func testLatencyCeilingIsEnforced() {
        let decision = PromotionGate.decide(candidate: report(replay: 0.99, latency: 4000), baseline: report(replay: 0.90))
        XCTAssertFalse(decision.isPromoted)
    }

    func testCompatibilityRejectsWrongBaseTokenizerHeadsAndSchema() {
        let base = manifest()
        let weights = Data("weights".utf8)
        let hash = SHA256.hash(data: weights).map { String(format: "%02x", $0) }.joined()

        XCTAssertNoThrow(try AdapterCompatibility.check(adapter(weightsHash: hash), baseManifest: base,
                                                        baseManifestChecksum: "base-checksum",
                                                        tokenizerChecksum: "tok-checksum", weights: weights))
        XCTAssertThrowsError(try AdapterCompatibility.check(adapter(baseChecksum: "other"), baseManifest: base,
                                                            baseManifestChecksum: "base-checksum",
                                                            tokenizerChecksum: "tok-checksum"))
        XCTAssertThrowsError(try AdapterCompatibility.check(adapter(tokenizer: "other"), baseManifest: base,
                                                            baseManifestChecksum: "base-checksum",
                                                            tokenizerChecksum: "tok-checksum"))
        XCTAssertThrowsError(try AdapterCompatibility.check(adapter(heads: ["choice"], weightsHash: hash), baseManifest: base,
                                                            baseManifestChecksum: "base-checksum",
                                                            tokenizerChecksum: "tok-checksum", weights: weights)) { error in
            XCTAssertEqual(error as? LoRAAdapterError, .missingHeads(["score", "noul"]))
        }
        XCTAssertThrowsError(try AdapterCompatibility.check(adapter(schema: 42, weightsHash: hash), baseManifest: base,
                                                            baseManifestChecksum: "base-checksum",
                                                            tokenizerChecksum: "tok-checksum", weights: weights))
        XCTAssertThrowsError(try AdapterCompatibility.check(adapter(weightsHash: "0"), baseManifest: base,
                                                            baseManifestChecksum: "base-checksum",
                                                            tokenizerChecksum: "tok-checksum", weights: weights)) { error in
            XCTAssertEqual(error as? LoRAAdapterError, .corruptedWeights)
        }
    }

    func testRollbackRestoresByteIdenticalWeights() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pp-adapter-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AdapterStore(root: root)

        let firstWeights = Data("first-adapter".utf8)
        let secondWeights = Data("second-adapter".utf8)
        try store.install(adapter(weightsHash: "a"), weights: firstWeights)
        try store.install(adapter(weightsHash: "b"), weights: secondWeights)
        XCTAssertEqual(store.active()?.weights, secondWeights)

        let restored = try store.rollback()
        XCTAssertEqual(restored.weights, firstWeights, "rollback must be byte-identical, not approximate")
        XCTAssertThrowsError(try store.rollback()) { error in
            XCTAssertEqual(error as? LoRAAdapterError, .nothingToRollBackTo)
        }
    }

    func testDeletingAdaptersLeavesTheBaseModelUsable() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pp-adapter-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AdapterStore(root: root)
        try store.install(adapter(), weights: Data("w".utf8))
        store.deleteAll()
        XCTAssertNil(store.active())
    }

    func testRejectedCandidateLeavesTheActiveAdapterUntouched() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pp-adapter-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AdapterStore(root: root)
        let incumbent = Data("incumbent".utf8)
        try store.install(adapter(weightsHash: "incumbent"), weights: incumbent)

        let candidateWeights = Data("candidate".utf8)
        let candidateHash = SHA256.hash(data: candidateWeights).map { String(format: "%02x", $0) }.joined()
        let trainer = FixedTrainer(package: adapter(weightsHash: candidateHash), weights: candidateWeights)
        let evaluator = FixedEvaluator(report: report(replay: 0.99, safety: 1.0, blocking: 1))
        let example = try XCTUnwrap(TrainingTraceBuilder.example(
            question: LayaQuestion(id: "t", type: "choice", instructions: "i", options: ["a", "b"], optionIDs: ["a", "b"]),
            selectedIndex: 0, succeeded: true, modelVersion: "1", structureFingerprint: "fp"))

        let decision = try store.trainEvaluateAndPromote(
            examples: [example], baseManifest: manifest(), baseManifestChecksum: "base-checksum",
            tokenizerChecksum: "tok-checksum", baseline: report(replay: 0.90),
            trainer: trainer, evaluator: evaluator)

        XCTAssertFalse(decision.isPromoted)
        XCTAssertEqual(store.active()?.weights, incumbent, "a rejected candidate must not replace the working adapter")
    }
}

private struct FixedTrainer: AdapterTraining {
    let package: LoRAAdapterPackage
    let weights: Data
    func train(examples: [TrainingExample], baseModelID: String) throws -> (package: LoRAAdapterPackage, weights: Data) {
        (package, weights)
    }
}

private struct FixedEvaluator: AdapterEvaluating {
    let report: EvaluationReport
    func evaluate(_ adapter: LoRAAdapterPackage, weights: Data) throws -> EvaluationReport { report }
}
