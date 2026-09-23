import Foundation

public struct NotificationRequestDescriptor: Sendable, Equatable {
    public let identifier: String
    public let title: String
    public let body: String
    public let targetDate: Date?
    public let timeInterval: TimeInterval?

    public init(identifier: String, title: String, body: String, targetDate: Date? = nil, timeInterval: TimeInterval? = nil) {
        self.identifier = identifier
        self.title = title
        self.body = body
        self.targetDate = targetDate
        self.timeInterval = timeInterval
    }
}

public protocol NotificationScheduling: Sendable {
    func isAuthorized() async -> Bool
    func requestAuthorization() async throws -> Bool
    func add(descriptor: NotificationRequestDescriptor) async throws
    func pendingRequests() async -> [NotificationRequestDescriptor]
    func removePendingRequests(withIdentifiers identifiers: [String]) async
}
