import Foundation

/// Configurable decision endpoint defaulting to local dev stub.
public enum DecisionEndpoint {
    public static let userDefaultsKey = "DecisionEndpoint"
    public static let defaultURL = URL(string: "http://127.0.0.1:8000/v1/systemone")!

    public static var currentURL: URL {
        if let stored = UserDefaults.standard.string(forKey: userDefaultsKey),
           let parsed = URL(string: stored) {
            return parsed
        }
        return defaultURL
    }
}
