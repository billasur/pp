import Foundation

/// Lightweight Chrome DevTools Protocol client using URLSessionWebSocketTask.
public actor CDPClient {
    private var webSocketTask: URLSessionWebSocketTask?
    private var nextMessageId = 1
    private var pendingContinuations: [Int: CheckedContinuation<[String: Any], Error>] = [:]

    public enum CDPError: LocalizedError {
        case notConnected
        case timeout
        case evaluationFailed(String)
        case invalidResponse

        public var errorDescription: String? {
            switch self {
            case .notConnected: return "CDP client not connected."
            case .timeout: return "CDP request timed out."
            case .evaluationFailed(let msg): return "CDP evaluation failed: \(msg)"
            case .invalidResponse: return "Invalid CDP response format."
            }
        }
    }

    public init() {}

    public func connect(to url: URL) {
        disconnect()
        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: url)
        self.webSocketTask = task
        task.resume()
        listen()
    }

    public func disconnect() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        for (_, cont) in pendingContinuations {
            cont.resume(throwing: CDPError.notConnected)
        }
        pendingContinuations.removeAll()
    }

    private func listen() {
        guard let task = webSocketTask else { return }
        task.receive { [weak self] result in
            Task { [weak self] in
                guard let self else { return }
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text):
                        await self.handleIncomingMessage(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            await self.handleIncomingMessage(text)
                        }
                    @unknown default:
                        break
                    }
                    await self.listen()
                case .failure:
                    await self.disconnect()
                }
            }
        }
    }

    private func handleIncomingMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? Int else { return }

        if let cont = pendingContinuations.removeValue(forKey: id) {
            cont.resume(returning: json)
        }
    }

    public func sendCommand(method: String, params: [String: Any] = [:], timeout: TimeInterval = 2.0) async throws -> [String: Any] {
        guard let task = webSocketTask else { throw CDPError.notConnected }

        let id = nextMessageId
        nextMessageId += 1

        let payload: [String: Any] = [
            "id": id,
            "method": method,
            "params": params
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let message = URLSessionWebSocketTask.Message.data(data)

        try await task.send(message)

        return try await withThrowingTaskGroup(of: [String: Any].self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    Task { [weak self] in
                        await self?.registerContinuation(continuation, for: id)
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw CDPError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func registerContinuation(_ continuation: CheckedContinuation<[String: Any], Error>, for id: Int) {
        pendingContinuations[id] = continuation
    }

    /// Evaluates a JavaScript expression on the inspected target page.
    public func evaluate(expression: String, timeout: TimeInterval = 2.0) async throws -> Any? {
        let response = try await sendCommand(method: "Runtime.evaluate", params: [
            "expression": expression,
            "returnByValue": true
        ], timeout: timeout)

        if let error = response["error"] as? [String: Any],
           let msg = error["message"] as? String {
            throw CDPError.evaluationFailed(msg)
        }
        guard let result = response["result"] as? [String: Any] else {
            throw CDPError.invalidResponse
        }
        if let subResult = result["result"] as? [String: Any] {
            return subResult["value"]
        }
        return result["value"]
    }

    /// Dispatches a synthetic mouse event at (x, y).
    public func dispatchMouseEvent(type: String, x: Double, y: Double, button: String = "left", clickCount: Int = 1) async throws {
        _ = try await sendCommand(method: "Input.dispatchMouseEvent", params: [
            "type": type,
            "x": x,
            "y": y,
            "button": button,
            "clickCount": clickCount
        ])
    }
}
