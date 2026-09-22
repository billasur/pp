import Foundation

/// Turns one spoken command into an ordered list of steps.
public protocol PlannerProvider: Sendable {
    /// Shown in the log and the UI so the active planner is never a mystery.
    var name: String { get }
    /// True when the planner needs the network at all.
    var requiresNetwork: Bool { get }
    func plan(utterance: String, frontApp: String, runningApps: [String]) async throws -> [PlanStep]
}

/// The deterministic planner. Zero latency, zero network, works offline.
public struct GrammarPlannerProvider: PlannerProvider {
    public let name = "local-grammar"
    public let requiresNetwork = false

    public init() {}

    public func plan(utterance: String, frontApp: String, runningApps: [String]) async throws -> [PlanStep] {
        let steps = GrammarPlanner.plan(utterance: utterance, frontApp: frontApp, runningApps: runningApps)
        guard !steps.isEmpty else { throw PlannerError.invalidResponse }
        return steps
    }
}

/// A loopback-only planner that talks to an OpenAI-compatible server the user runs
/// themselves (llama.cpp, Ollama, vLLM, MLX server).
///
/// In-process MLX Swift language-model planning is the intended long-term home for
/// this, but it needs a decoder stack pp does not ship yet. Until then this is the
/// honest way to offer an LLM planner: the user brings the server, pp never leaves the
/// machine, and a non-loopback endpoint is refused outright rather than silently
/// becoming a cloud call.
public struct LocalServerPlanner: PlannerProvider {
    public let name = "local-server"
    public let requiresNetwork = false  // loopback only
    public let endpoint: URL
    public let model: String

    public init(endpoint: URL, model: String = "local") throws {
        guard PlannerEndpointPolicy.isLoopback(endpoint) else {
            throw PlannerEndpointPolicy.PolicyError.notLoopback(endpoint.host ?? "unknown")
        }
        self.endpoint = endpoint
        self.model = model
    }

    public func plan(utterance: String, frontApp: String, runningApps: [String]) async throws -> [PlanStep] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": Planner.systemInstructions],
                ["role": "user", "content": "Frontmost app: \(frontApp). Running apps: \(runningApps.joined(separator: ", ")).\nSpoken command: \(utterance)"]
            ],
            "temperature": 0
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw PlannerError.invalidResponse
        }
        return try Planner.steps(from: data)
    }
}

/// Refuses planner endpoints that are not on this machine.
public enum PlannerEndpointPolicy {
    public struct PolicyError: LocalizedError, Equatable {
        public let message: String
        public var errorDescription: String? { message }

        public static func notLoopback(_ host: String) -> PolicyError {
            PolicyError(message: "Planner endpoint '\(host)' is not on this machine. pp only talks to a local planner, so the command would have to leave the Mac; it was refused.")
        }
    }

    /// Loopback, or the literal "localhost". Anything else is refused.
    ///
    /// The host is parsed as exactly four numeric components, so a name that merely
    /// begins with the loopback prefix — `127.0.0.1.evil.com` — is a foreign host, not
    /// a local one.
    public static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
        if host == "localhost" || host == "::1" { return true }

        let components = host.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4 else { return false }
        let octets = components.compactMap { part -> Int? in
            guard !part.isEmpty, part.allSatisfy(\.isNumber), part.count <= 3, let value = Int(part) else { return nil }
            return (0...255).contains(value) ? value : nil
        }
        guard octets.count == 4 else { return false }
        return octets[0] == 127
    }
}

/// Planner that always refuses, for tests that must prove nothing else ran.
public struct StubPlanner: PlannerProvider {
    public let name = "stub"
    public let requiresNetwork = false
    public let steps: [PlanStep]

    public init(steps: [PlanStep] = []) { self.steps = steps }

    public func plan(utterance: String, frontApp: String, runningApps: [String]) async throws -> [PlanStep] {
        guard !steps.isEmpty else { throw PlannerError.invalidResponse }
        return steps
    }
}

/// Replays recorded planner output, so integration tests need no model and no server.
public struct RecordedPlanner: PlannerProvider {
    public let name = "recorded"
    public let requiresNetwork = false
    private let table: [String: [PlanStep]]

    public init(table: [String: [PlanStep]]) { self.table = table }

    public func plan(utterance: String, frontApp: String, runningApps: [String]) async throws -> [PlanStep] {
        let key = utterance.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard let steps = table[key] else { throw PlannerError.invalidResponse }
        return steps
    }
}

/// Time, so anything scheduled can be tested without waiting.
public protocol TimeSource: Sendable {
    var now: Date { get }
}

public struct SystemTime: TimeSource {
    public init() {}
    public var now: Date { Date() }
}

public struct TestClock: TimeSource {
    public var current: Date
    public init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) { current = start }
    public var now: Date { current }
    public mutating func advance(_ seconds: TimeInterval) { current = current.addingTimeInterval(seconds) }
}
