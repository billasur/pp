import Foundation

public protocol ScriptProposing: Sendable {
    func propose(goal: String, frontApp: String) async throws -> String
}

public enum ScriptGateError: LocalizedError, Equatable {
    case compileFailed(String)
    case noEffect(String)
    case policyViolation(String)
    case verificationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .compileFailed(let msg): return "AppleScript compilation failed: \(msg)"
        case .noEffect(let msg): return "Script has no measurable effect: \(msg)"
        case .policyViolation(let reason): return "Blocked by security policy: \(reason)"
        case .verificationFailed(let msg): return "Script failed verification: \(msg)"
        }
    }
}

/// The four blocking gates for novel skill synthesis.
public enum ScriptGates {
    /// Gate 1: Compile check. Compiles source with osacompile.
    public static func checkCompile(source: String) -> Result<Void, ScriptGateError> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
        let pipe = Pipe()
        process.standardError = pipe

        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pp_gate_\(UUID().uuidString).scpt")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        process.arguments = ["-e", source, "-o", tempURL.path]
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                return .success(())
            } else {
                let errData = pipe.fileHandleForReading.readDataToEndOfFile()
                let errMsg = String(data: errData, encoding: .utf8) ?? "Unknown compiler error"
                return .failure(.compileFailed(errMsg.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        } catch {
            return .failure(.compileFailed(error.localizedDescription))
        }
    }

    /// Gate 2: Effect check. Must contain actionable verbs.
    public static func checkEffect(source: String) -> Result<Void, ScriptGateError> {
        let lowered = source.lowercased()
        let effectPatterns = [
            "keystroke",
            "key code",
            "click",
            "set volume",
            "set value",
            "tell application \".*\" to (make|delete|set|close|open|activate|quit)"
        ]

        var hasEffect = false
        for pattern in effectPatterns {
            if (try? NSRegularExpression(pattern: pattern, options: .caseInsensitive).firstMatch(in: lowered, range: NSRange(lowered.startIndex..., in: lowered))) != nil {
                hasEffect = true
                break
            }
        }

        // Also check direct keywords
        if lowered.contains("keystroke") || lowered.contains("key code") || lowered.contains("click") || lowered.contains("set bounds") || lowered.contains("set position") || lowered.contains("set size") {
            hasEffect = true
        }

        if hasEffect {
            return .success(())
        }
        return .failure(.noEffect("Script contains no action or effect commands."))
    }

    /// Gate 3: Policy check. Blocklists sensitive system paths, bans shell scripts, and runs against decompile output.
    public static func checkPolicy(source: String) -> Result<Void, ScriptGateError> {
        // Cap script length
        if source.count > 2000 {
            return .failure(.policyViolation("Script exceeds maximum allowable length of 2000 characters."))
        }

        let lowered = source.lowercased()

        // Unconditionally ban shell scripts in v2.1
        if lowered.contains("do shell script") {
            var details = ["Execution of shell scripts ('do shell script') is strictly forbidden."]
            let shellBlocked = ["rm ", "rm -rf", "rmdir", "curl", "chmod", "chown", "wget", "kill", "eval", "sh", "bash", "zsh"]
            for bad in shellBlocked {
                if lowered.contains(bad) {
                    details.append("Shell command contains dangerous utility ('\(bad)').")
                }
            }
            let blockedSubstrings = ["/system", "/library", "/usr", "/bin", "/sbin", "~/.ssh", ".ssh", ".env", "keychain", "terminal", "iterm", "sudo", "launchctl", "defaults delete", "osascript"]
            for blocked in blockedSubstrings {
                if lowered.contains(blocked) {
                    details.append("Script touches protected target or command ('\(blocked)').")
                }
            }
            return .failure(.policyViolation(details.joined(separator: " ")))
        }

        let blockedSubstrings = [
            "/system",
            "/library",
            "/usr",
            "/bin",
            "/sbin",
            "~/.ssh",
            ".ssh",
            ".env",
            "keychain",
            "terminal",
            "iterm",
            "sudo",
            "launchctl",
            "defaults delete",
            "osascript",
            "curl",
            "wget"
        ]

        for blocked in blockedSubstrings {
            if lowered.contains(blocked) {
                return .failure(.policyViolation("Script touches protected target or command ('\(blocked)')."))
            }
        }

        // Compile and decompile to inspect resolved string literals preventing concatenation bypasses
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pp_check_\(UUID().uuidString).scpt")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let compileProcess = Process()
        compileProcess.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
        compileProcess.arguments = ["-e", source, "-o", tempURL.path]
        try? compileProcess.run()
        compileProcess.waitUntilExit()

        if compileProcess.terminationStatus == 0 {
            let decompileProcess = Process()
            let pipe = Pipe()
            decompileProcess.executableURL = URL(fileURLWithPath: "/usr/bin/osadecompile")
            decompileProcess.arguments = [tempURL.path]
            decompileProcess.standardOutput = pipe
            try? decompileProcess.run()
            decompileProcess.waitUntilExit()

            let decompiledData = pipe.fileHandleForReading.readDataToEndOfFile()
            if let decompiled = String(data: decompiledData, encoding: .utf8)?.lowercased() {
                for blocked in blockedSubstrings {
                    if decompiled.contains(blocked) {
                        return .failure(.policyViolation("Compiled script resolves to protected target ('\(blocked)')."))
                    }
                }
            }
        }

        return .success(())
    }

    /// Gate 4: Verification check (probability that script matches goal).
    public static func checkVerification(probability: Double, threshold: Double = 0.4) -> Result<Void, ScriptGateError> {
        if probability >= threshold {
            return .success(())
        }
        return .failure(.verificationFailed("P(script achieves goal) = \(probability) < \(threshold)"))
    }

    /// Evaluates all 4 gates in order. Requires explicit probability score.
    public static func evaluateAll(source: String, probability: Double) -> Result<Void, ScriptGateError> {
        switch checkCompile(source: source) {
        case .failure(let err): return .failure(err)
        case .success: break
        }

        switch checkEffect(source: source) {
        case .failure(let err): return .failure(err)
        case .success: break
        }

        switch checkPolicy(source: source) {
        case .failure(let err): return .failure(err)
        case .success: break
        }

        switch checkVerification(probability: probability) {
        case .failure(let err): return .failure(err)
        case .success: break
        }

        return .success(())
    }
}
