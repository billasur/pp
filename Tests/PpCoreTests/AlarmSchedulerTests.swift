import XCTest
@testable import PpCore

private final class FakeNotificationScheduler: NotificationScheduling, @unchecked Sendable {
    var authorized = false
    var requests: [NotificationRequestDescriptor] = []

    func isAuthorized() async -> Bool {
        return authorized
    }

    func requestAuthorization() async throws -> Bool {
        return authorized
    }

    func add(descriptor: NotificationRequestDescriptor) async throws {
        requests.append(descriptor)
    }

    func pendingRequests() async -> [NotificationRequestDescriptor] {
        return requests
    }

    func removePendingRequests(withIdentifiers identifiers: [String]) async {
        requests.removeAll(where: { identifiers.contains($0.identifier) })
    }
}

final class AlarmSchedulerTests: XCTestCase {
    private var tempDir: URL!
    private var store: AlarmStore!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let file = tempDir.appendingPathComponent("alarms.json")
        store = AlarmStore(fileURL: file)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testHappyPathAlarmScheduling() async throws {
        let fake = FakeNotificationScheduler()
        fake.authorized = true
        let scheduler = AlarmScheduler(store: store, scheduler: fake)

        let target = Date().addingTimeInterval(3600)
        let (item, verified, authorized) = try await scheduler.scheduleAlarm(targetDate: target, label: "Wake up")

        XCTAssertTrue(authorized)
        XCTAssertTrue(verified)
        XCTAssertEqual(item.label, "Wake up")
        XCTAssertEqual(fake.requests.count, 1)
        XCTAssertEqual(fake.requests.first?.identifier, item.id)
    }

    func testDeniedAuthorizationReturnsUnverifiedAndUnauthorized() async throws {
        let fake = FakeNotificationScheduler()
        fake.authorized = false
        let scheduler = AlarmScheduler(store: store, scheduler: fake)

        let target = Date().addingTimeInterval(3600)
        let (item, verified, authorized) = try await scheduler.scheduleAlarm(targetDate: target, label: "Wake up")

        XCTAssertFalse(authorized)
        XCTAssertFalse(verified, "Denied notification permission must never report verified: true")
        XCTAssertEqual(item.label, "Wake up")
    }

    func testPendingButUnauthorizedReportsUnverified() async throws {
        let fake = FakeNotificationScheduler()
        fake.authorized = false
        // Even if requests somehow exist in pending, unauthorized must yield verified: false
        fake.requests.append(NotificationRequestDescriptor(identifier: "fake-id", title: "pp Alarm", body: "Wake up"))
        let scheduler = AlarmScheduler(store: store, scheduler: fake)

        let target = Date().addingTimeInterval(3600)
        let (_, verified, authorized) = try await scheduler.scheduleAlarm(targetDate: target, label: "Wake up")

        XCTAssertFalse(authorized)
        XCTAssertFalse(verified)
    }

    func testCancelRemovesFromStoreAndScheduler() async throws {
        let fake = FakeNotificationScheduler()
        fake.authorized = true
        let scheduler = AlarmScheduler(store: store, scheduler: fake)

        let target = Date().addingTimeInterval(1800)
        let (item, _, _) = try await scheduler.scheduleAlarm(targetDate: target, label: "Tea")
        XCTAssertEqual(fake.requests.count, 1)

        let cancelled = await scheduler.cancel(target: "Tea")
        XCTAssertEqual(cancelled.count, 1)
        XCTAssertEqual(cancelled.first?.id, item.id)
        XCTAssertEqual(fake.requests.count, 0)
    }
}
