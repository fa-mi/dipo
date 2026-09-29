import XCTest
import SwiftData
@testable import DiPo

/// A store that won't open used to be deleted. These pin that it is moved
/// aside instead — every byte of it — and that the user is told.
///
/// The other branch, a device still locked from a reboot, has no test here: it
/// turns on `UIApplication.isProtectedDataAvailable`, which cannot be faked,
/// and it ends in `exit(0)`, which would take the test runner with it. What
/// these tests do cover is the part that matters for that branch being safe —
/// an UNLOCKED device never stops the launch, it quarantines and opens.
@MainActor
final class StoreRecoveryTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoreRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        StoreRecovery.acknowledge()
    }

    override func tearDownWithError() throws {
        StoreRecovery.acknowledge()
        try? FileManager.default.removeItem(at: dir)
    }

    func testUnopenableStoreIsMovedAsideNotDeleted() throws {
        let store = dir.appendingPathComponent("default.store")
        let garbage = Data("not a database, but somebody's ledger".utf8)
        try garbage.write(to: store)
        try Data("wal".utf8).write(to: dir.appendingPathComponent("default.store-wal"))
        try Data("unrelated".utf8).write(to: dir.appendingPathComponent("other.plist"))

        let schema = Schema([BankCard.self, TxRecord.self, SalarySchedule.self, DebtRecord.self, SavingsGoal.self])
        let config = ModelConfiguration(schema: schema, url: store)
        let container = StoreRecovery.openContainer(schema: schema, config: config)

        // A usable, empty store in the original place.
        let cards = try ModelContext(container).fetch(FetchDescriptor<BankCard>())
        XCTAssertTrue(cards.isEmpty)

        // The old bytes survive, byte for byte, under StoreQuarantine/.
        let notice = try XCTUnwrap(StoreRecovery.pendingNotice)
        let folder = dir.appendingPathComponent("StoreQuarantine").appendingPathComponent(notice.folder)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("default.store")), garbage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("default.store-wal").path))

        // Only the store's own files move.
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("other.plist").path))
        XCTAssertFalse(notice.reported)
    }

    func testHealthyStoreRaisesNoNotice() throws {
        let schema = Schema([BankCard.self, TxRecord.self, SalarySchedule.self, DebtRecord.self, SavingsGoal.self])
        let config = ModelConfiguration(schema: schema, url: dir.appendingPathComponent("default.store"))
        _ = StoreRecovery.openContainer(schema: schema, config: config)
        XCTAssertNil(StoreRecovery.pendingNotice)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("StoreQuarantine").path))
    }
}
