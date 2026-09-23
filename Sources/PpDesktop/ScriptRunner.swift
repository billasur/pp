import Foundation
import AppKit

public enum ScriptRunnerError: LocalizedError {
    case executionTimeout
    case executionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .executionTimeout: return "AppleScript execution timed out."
        case .executionFailed(let msg): return "AppleScript error: \(msg)"
        }
    }
}

/// Executes AppleScripts safely with a strict wall-clock timeout.
public enum ScriptRunner {
    @MainActor
    public static func run(source: String, timeout: TimeInterval = 3.0) async throws -> String? {
        try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask { @MainActor in
                var error: NSDictionary?
                guard let script = NSAppleScript(source: source) else {
                    throw ScriptRunnerError.executionFailed("Could not initialize script.")
                }
                let descriptor = script.executeAndReturnError(&error)
                if let error {
                    let errMsg = error[NSAppleScript.errorMessage] as? String ?? "Execution error"
                    throw ScriptRunnerError.executionFailed(errMsg)
                }
                return descriptor.stringValue
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw ScriptRunnerError.executionTimeout
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
