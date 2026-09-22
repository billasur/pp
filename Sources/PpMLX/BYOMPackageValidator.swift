import Foundation
import PpCore

/// One check in a compatibility run.
public struct BYOMCheck: Equatable, Sendable {
    public let name: String
    public let passed: Bool
    public let detail: String
}

public struct BYOMReport: Equatable, Sendable {
    public let checks: [BYOMCheck]
    public var passed: Bool { checks.allSatisfy(\.passed) }
    public var failures: [BYOMCheck] { checks.filter { !$0.passed } }
}

/// Validates a bring-your-own-model package before pp will load it.
///
/// "MLX can open the file" is not the same as "this is a Laya decision model". A
/// checkpoint with the right tensor shapes but the wrong tokenizer, wrong special-token
/// ids, or a missing decision head will load happily and then answer nonsense, which
/// looks like a UX bug rather than a bad model. So the contract is checked explicitly.
public enum BYOMPackageValidator {

    public static func validate(
        directory: URL,
        appVersion: String = ModelManager.currentVersion,
        deepSmokeTest: ((URL) throws -> Void)? = nil
    ) throws -> BYOMReport {
        var checks: [BYOMCheck] = []

        // 1. Manifest present and structurally compatible.
        guard let manifest = ModelManager.manifest(of: directory) else {
            return BYOMReport(checks: [BYOMCheck(name: "manifest", passed: false, detail: "No readable manifest.json.")])
        }
        do {
            try ModelManager.validate(manifest, appVersion: appVersion)
            checks.append(BYOMCheck(name: "manifest", passed: true, detail: "Architecture, precision, heads and minimum version are compatible."))
        } catch {
            checks.append(BYOMCheck(name: "manifest", passed: false, detail: error.localizedDescription))
        }

        // 2. Every declared file matches its checksum.
        let verified = ModelManager.verify(directory: directory, full: true)
        checks.append(BYOMCheck(name: "checksums", passed: verified,
                                detail: verified ? "All listed files match their recorded sizes and hashes." : "A file is missing, the wrong size, or fails its hash."))

        // 3. Declared special-token ids match what the tokenizer actually defines.
        let tokenCheck = verifySpecialTokens(directory: directory, manifest: manifest)
        checks.append(tokenCheck)

        // 4. The tokenizer and sequence builder still produce the Laya layout.
        let sequenceCheck = verifySequenceContract(directory: directory)
        checks.append(sequenceCheck)

        // 5. A step that sends data must still be gated. A model cannot opt out of this.
        let gate = SafetyCritic.evaluate(step: PlanStep(kind: .click, target: "Send"), goal: "send the message")
        checks.append(BYOMCheck(name: "safety-gate", passed: gate.isBlocked,
                                detail: gate.isBlocked ? "Outward actions still require confirmation." : "The safety gate did not fire."))

        // 6. Optional deep check: actually load and run each head.
        if let deepSmokeTest {
            do {
                try deepSmokeTest(directory)
                checks.append(BYOMCheck(name: "heads", passed: true, detail: "The model loaded and every decision head produced finite scores."))
            } catch {
                checks.append(BYOMCheck(name: "heads", passed: false, detail: error.localizedDescription))
            }
        }

        return BYOMReport(checks: checks)
    }

    /// Compares the manifest's declared ids with tokenizer.json.
    static func verifySpecialTokens(directory: URL, manifest: ModelManager.Manifest) -> BYOMCheck {
        guard let declared = manifest.specialTokens else {
            return BYOMCheck(name: "special-tokens", passed: false, detail: "The manifest declares no special-token ids.")
        }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("tokenizer.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let added = object["added_tokens"] as? [[String: Any]] else {
            return BYOMCheck(name: "special-tokens", passed: false, detail: "tokenizer.json has no added_tokens table.")
        }

        var byContent: [String: Int] = [:]
        for token in added {
            if let content = token["content"] as? String, let id = token["id"] as? Int {
                byContent[content] = id
            }
        }

        let expectations: [(String, Int?)] = [
            ("[CLS]", declared.cls), ("[SEP]", declared.sep),
            ("[PAD]", declared.pad), ("[MASK]", declared.mask)
        ]
        for (content, expected) in expectations {
            guard let expected else {
                return BYOMCheck(name: "special-tokens", passed: false, detail: "The manifest omits \(content).")
            }
            guard let actual = byContent[content] else {
                return BYOMCheck(name: "special-tokens", passed: false, detail: "The tokenizer does not define \(content).")
            }
            guard actual == expected else {
                return BYOMCheck(name: "special-tokens", passed: false,
                                 detail: "\(content) is \(actual) in the tokenizer but \(expected) in the manifest. Sequences would be built against the wrong marker.")
            }
        }
        return BYOMCheck(name: "special-tokens", passed: true, detail: "Declared ids match the tokenizer's own definitions.")
    }

    /// Builds a sequence with the package's tokenizer and checks the layout invariants.
    static func verifySequenceContract(directory: URL) -> BYOMCheck {
        guard let tokenizer = try? BPETokenizer.load(from: directory) else {
            return BYOMCheck(name: "sequence", passed: false, detail: "The package tokenizer could not be loaded.")
        }

        let built = SequenceBuilder.buildSequence(
            tokenizer: tokenizer,
            state: "Application: Finder, Command: open notes",
            questionType: "choice",
            instructions: "Which control should be used?",
            options: ["Open: open the notes", "Close: close the window"],
            maxLen: 512)

        guard built.inputIds.first == tokenizer.clsTokenId else {
            return BYOMCheck(name: "sequence", passed: false, detail: "The sequence does not start with the CLS token.")
        }
        guard built.markers.count == 2 else {
            return BYOMCheck(name: "sequence", passed: false, detail: "Expected one marker per option, found \(built.markers.count).")
        }
        for marker in built.markers where built.inputIds[safeIndex: marker] != tokenizer.maskTokenId {
            return BYOMCheck(name: "sequence", passed: false, detail: "An option marker does not point at the MASK token.")
        }
        guard built.inputIds.count <= 512 else {
            return BYOMCheck(name: "sequence", passed: false, detail: "The sequence exceeded the 512-token budget.")
        }

        // Many-option case: the head block must shrink option text rather than overflow.
        let many = (0..<20).map { "Option \($0): description number \($0) with some extra words" }
        let wide = SequenceBuilder.buildSequence(
            tokenizer: tokenizer, state: "state", questionType: "choice",
            instructions: "Pick one.", options: many, maxLen: 512)
        guard wide.markers.count == 20 else {
            return BYOMCheck(name: "sequence", passed: false, detail: "Options were dropped instead of truncated.")
        }
        guard wide.inputIds.count <= 512 else {
            return BYOMCheck(name: "sequence", passed: false, detail: "The wide-option sequence exceeded the budget.")
        }

        return BYOMCheck(name: "sequence", passed: true, detail: "Sequence layout matches the Laya contract, including the many-option shrink path.")
    }

    /// Deep check used before activation: load the model and run every head.
    public static func deepSmokeTest(_ directory: URL) throws {
        let model = try LayaModel.load(from: directory)
        let tokenizer = try BPETokenizer.load(from: directory)

        for (type, options) in [("choice", ["a: first", "b: second", "c: third"]),
                                ("noul", ["false: no", "true: yes"]),
                                ("score", ["level 0: bad", "level 1: ok", "level 2: good"])] {
            let built = SequenceBuilder.buildSequence(
                tokenizer: tokenizer, state: "state", questionType: type,
                instructions: "Smoke question.", options: options, maxLen: 512)
            let prediction = model.evaluate(inputIds: built.inputIds, markerPositions: built.markers, questionType: type)
            guard prediction.logits.count == options.count else {
                throw NSError(domain: "pp.byom", code: 1, userInfo: [NSLocalizedDescriptionKey: "The \(type) head returned \(prediction.logits.count) scores for \(options.count) options."])
            }
            guard prediction.logits.allSatisfy({ $0.isFinite }) else {
                throw NSError(domain: "pp.byom", code: 2, userInfo: [NSLocalizedDescriptionKey: "The \(type) head produced a non-finite score."])
            }
        }
    }
}

private extension Array {
    subscript(safeIndex index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
