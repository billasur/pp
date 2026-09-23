import XCTest
@testable import PpCore

final class AlarmStoreTests: XCTestCase {
    func testPersistenceRoundTrip() async {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storeURL = tempDir.appendingPathComponent("alarms.json")
        let store1 = AlarmStore(fileURL: storeURL)

        let date1 = Date().addingTimeInterval(3600)
        let item1 = ScheduledItem(id: "alarm-1", kind: .alarm, label: "Wake up", targetDate: date1)
        await store1.add(item1)

        let store2 = AlarmStore(fileURL: storeURL)
        await store2.load()

        let all = await store2.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.id, "alarm-1")
        XCTAssertEqual(all.first?.label, "Wake up")
        XCTAssertEqual(all.first?.kind, .alarm)

        let nextItem = await store2.next(after: Date())
        XCTAssertEqual(nextItem?.id, "alarm-1")

        let cancelled = await store2.cancel(id: "alarm-1")
        XCTAssertEqual(cancelled?.id, "alarm-1")

        let allAfterCancel = await store2.all()
        XCTAssertTrue(allAfterCancel.isEmpty)
    }
}
