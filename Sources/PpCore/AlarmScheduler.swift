import Foundation

public actor AlarmScheduler {
    public static let shared = AlarmScheduler()
    private let scheduler: any NotificationScheduling
    private let store: AlarmStore
    private var authorized: Bool?

    public init(store: AlarmStore = AlarmStore(), scheduler: any NotificationScheduling = SystemNotificationScheduler.shared) {
        self.store = store
        self.scheduler = scheduler
    }

    public func requestAuthorizationIfNeeded() async -> Bool {
        if let auth = authorized, auth { return true }
        let currentAuth = await scheduler.isAuthorized()
        if currentAuth {
            authorized = true
            return true
        }
        do {
            let granted = try await scheduler.requestAuthorization()
            authorized = granted
            return granted
        } catch {
            authorized = false
            return false
        }
    }

    public func scheduleAlarm(targetDate: Date, label: String) async throws -> (item: ScheduledItem, readBackVerified: Bool, authorized: Bool) {
        let isAuth = await requestAuthorizationIfNeeded()

        let item = ScheduledItem(kind: .alarm, label: label, targetDate: targetDate)
        await store.add(item)

        let desc = NotificationRequestDescriptor(
            identifier: item.id,
            title: "pp Alarm",
            body: label.isEmpty ? "Alarm" : label,
            targetDate: targetDate
        )
        try await scheduler.add(descriptor: desc)

        // Read-back verification requires BOTH pending request presence AND active authorization
        let pending = await scheduler.pendingRequests()
        let isPending = pending.contains(where: { $0.identifier == item.id })
        let readBackVerified = isPending && isAuth
        return (item, readBackVerified, isAuth)
    }

    public func scheduleTimer(durationSeconds: TimeInterval, label: String) async throws -> (item: ScheduledItem, readBackVerified: Bool, authorized: Bool) {
        let isAuth = await requestAuthorizationIfNeeded()

        let targetDate = Date().addingTimeInterval(durationSeconds)
        let item = ScheduledItem(kind: .timer, label: label, targetDate: targetDate)
        await store.add(item)

        let desc = NotificationRequestDescriptor(
            identifier: item.id,
            title: "pp Timer",
            body: label.isEmpty ? "Timer finished" : label,
            timeInterval: max(1, durationSeconds)
        )
        try await scheduler.add(descriptor: desc)

        // Read-back verification requires BOTH pending request presence AND active authorization
        let pending = await scheduler.pendingRequests()
        let isPending = pending.contains(where: { $0.identifier == item.id })
        let readBackVerified = isPending && isAuth
        return (item, readBackVerified, isAuth)
    }

    public func cancel(target: String?) async -> [ScheduledItem] {
        let removed = await store.cancelMatching(target: target)
        let ids = removed.map(\.id)
        await scheduler.removePendingRequests(withIdentifiers: ids)
        return removed
    }

    public func listAll() async -> [ScheduledItem] {
        await store.all()
    }

    public func nextFireDate(after date: Date = Date()) async -> Date? {
        await store.nextFireDate(after: date)
    }
}
