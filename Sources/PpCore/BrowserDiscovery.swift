import Foundation

/// Discovers running Chromium-based browsers exposing remote debugging ports.
public enum BrowserDiscovery {
    public static let standardPorts = [9222, 9229, 9333]

    public struct BrowserVersionInfo: Codable, Sendable {
        public let browser: String?
        public let webSocketDebuggerUrl: String?

        enum CodingKeys: String, CodingKey {
            case browser = "Browser"
            case webSocketDebuggerUrl = "webSocketDebuggerUrl"
        }
    }

    /// Probes 127.0.0.1 across standard ports (9222, 9229, 9333) with GET /json/version.
    public static func discoverWebSocketURL(ports: [Int] = standardPorts, timeout: TimeInterval = 0.5) async -> URL? {
        for port in ports {
            guard let url = URL(string: "http://127.0.0.1:\(port)/json/version") else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = timeout
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { continue }
                if let info = try? JSONDecoder().decode(BrowserVersionInfo.self, from: data),
                   let wsString = info.webSocketDebuggerUrl,
                   let wsURL = URL(string: wsString) {
                    return wsURL
                }
            } catch {
                continue
            }
        }
        return nil
    }
}
