import Foundation

public struct DecisionServiceError: LocalizedError, Equatable {
    public let status: Int
    public let message: String?

    public init(status: Int, message: String?) {
        self.status = status
        self.message = message
    }

    public var errorDescription: String? {
        switch status {
        case 401: return "Decision service rejected the API key. Check it in Settings."
        case 403: return "This API key does not have access to the selected model."
        case 429: return "Rate limit was reached. Try again shortly."
        case 529: return "Decision service is currently overloaded. Try again shortly."
        default: return "Decision service returned HTTP \(status). \(message ?? "Nothing was executed.")"
        }
    }
}

/// HTTP decision provider connecting to a local dev oracle or remote decision service.
public final class HTTPProvider: DecisionProvider, @unchecked Sendable {
    public let endpoint: URL
    public let session: URLSession

    public var requiresAPIKey: Bool { true }

    public init(endpoint: URL = DecisionEndpoint.currentURL, session: URLSession? = nil) {
        self.endpoint = endpoint
        if let session = session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.httpMaximumConnectionsPerHost = 2
            config.timeoutIntervalForRequest = 20
            self.session = URLSession(configuration: config)
        }
    }

    public func warmUp() {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "HEAD"
        session.dataTask(with: request).resume()
    }

    public func evaluate(context: CommandContext, candidates: [Candidate], apiKey: String?) async throws -> Decision {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        if let apiKey = apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JevClient.requestBody(context: context, candidates: candidates)
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw DecisionError.invalidResponse }
        guard (200...299).contains(response.statusCode) else {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let error = object?["error"] as? [String: Any]
            let validation = (object?["detail"] as? [[String: Any]])?.compactMap { $0["msg"] as? String }.joined(separator: "; ")
            let raw = String(decoding: data.prefix(400), as: UTF8.self)
            let message = error?["message"] as? String ?? object?["message"] as? String ?? object?["detail"] as? String ?? object?["error"] as? String ?? validation ?? raw
            let redacted = apiKey.map { message.replacingOccurrences(of: $0, with: "[redacted]") } ?? message
            throw DecisionServiceError(status: response.statusCode, message: redacted)
        }
        return try JSONDecoder().decode(Decision.self, from: data)
    }

    public func decide(context: CommandContext, candidates: [Candidate], apiKey: String?) async throws -> Decision {
        var remaining = candidates
        while true {
            let response = try await evaluate(context: context, candidates: remaining, apiKey: apiKey)
            guard remaining.count > JevClient.actionsPerQuestion else { return response }
            func single(_ answer: Decision.Answer) -> Decision {
                Decision(answers: ["action": answer, "more": response.answers["more"]].compactMapValues { $0 })
            }
            var matches: [Candidate] = []
            var noMatch: Decision.Answer?
            for (index, lower) in stride(from: 0, to: remaining.count, by: JevClient.actionsPerQuestion).enumerated() {
                guard let answer = response.answers["batch_\(index)"], answer.type == "choice",
                      let confidence = answer.confidence, (0...1).contains(confidence) else { throw DecisionError.invalidResponse }
                if ["cancel", "clarify", "done"].contains(answer.choice) { return single(answer) }
                if answer.choice == "unavailable" { noMatch = answer; continue }
                let group = Array(remaining[lower..<min(lower + JevClient.actionsPerQuestion, remaining.count)])
                let candidate = try single(answer).selectedCandidate(from: group)
                matches.append(candidate)
            }
            if matches.isEmpty {
                guard let noMatch else { throw DecisionError.invalidResponse }
                return single(noMatch)
            }
            if matches.count == 1, let index = response.answers.keys.first(where: { key in
                key.hasPrefix("batch_") && response.answers[key]?.choice == matches[0].id }) {
                return single(response.answers[index]!)
            }
            remaining = matches
        }
    }

    public func cycle(state: JevClient.CycleState, operations: [String: String], heads: [String: [String: String]], apiKey: String?) async throws -> Decision {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        if let apiKey = apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JevClient.cycleBody(state: state, operations: operations, heads: heads)
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw DecisionError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            let raw = String(decoding: data.prefix(400), as: UTF8.self)
            let redacted = apiKey.map { raw.replacingOccurrences(of: $0, with: "[redacted]") } ?? raw
            throw DecisionServiceError(status: http.statusCode, message: redacted)
        }
        return try JSONDecoder().decode(Decision.self, from: data)
    }

    public func ground(context: JevClient.GroundingContext, candidates: [Candidate], apiKey: String?) async throws -> Decision {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        if let apiKey = apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JevClient.groundingBody(context: context, candidates: candidates)
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw DecisionError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            let raw = String(decoding: data.prefix(400), as: UTF8.self)
            let redacted = apiKey.map { raw.replacingOccurrences(of: $0, with: "[redacted]") } ?? raw
            throw DecisionServiceError(status: http.statusCode, message: redacted)
        }
        return try JSONDecoder().decode(Decision.self, from: data)
    }
}
