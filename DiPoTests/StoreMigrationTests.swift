import XCTest
import SwiftData
@testable import DiPo

/// Every phone with DiPo on it holds a store written WITHOUT a schema version.
/// Declaring V1 must open those stores as they are — if it didn't, every user
/// would land in StoreRecovery's quarantine on the update that ships this.
@MainActor
final class StoreMigrationTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoreMigrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        StoreRecovery.acknowledge()
    }

    override func tearDownWithError() throws {
        StoreRecovery.acknowledge()
        UserDefaults.standard.removeObject(forKey: "dipo_store_unplanned_migration")
        try? FileManager.default.removeItem(at: dir)
    }

    /// Writes a store the way builds before versioning did: a bare Schema of
    /// the same models, no migration plan.
    private func writeUnversionedStore(at url: URL) throws -> (cardID: UUID, txID: UUID) {
        let schema = Schema(DiPoSchemaV1.models)
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
        let context = ModelContext(container)
        let card = BankCard(holderName: "Lama", cardNumber: "423456••••••7890",
                            balance: 1_250_000, expireDate: "12/30",
                            gradientStart: "#000000", gradientEnd: "#111111",
                            sortOrder: 0, currency: "IDR")
        context.insert(card)
        let tx = TxRecord(name: "Pupuk", date: .now, amount: 85_000, type: "Expense",
                          icon: "leaf.fill", iconBgHex: "#000000", category: .other,
                          currency: "IDR")
        context.insert(tx)
        card.transactions.append(tx)
        try context.save()
        return (card.id, tx.id)
    }

    func testUnversionedStoreOpensUnderV1WithItsRows() throws {
        let url = dir.appendingPathComponent("default.store")
        let ids = try writeUnversionedStore(at: url)

        // Opened directly, not through StoreRecovery, so a failure is a thrown
        // error here rather than a silent quarantine.
        let schema = Schema(versionedSchema: DiPoSchemaCurrent.self)
        let container = try ModelContainer(for: schema, migrationPlan: DiPoMigrationPlan.self,
                                           configurations: ModelConfiguration(schema: schema, url: url))
        let context = ModelContext(container)

        let cards = try context.fetch(FetchDescriptor<BankCard>())
        XCTAssertEqual(cards.map(\.id), [ids.cardID])
        XCTAssertEqual(cards.first?.balance, 1_250_000)
        XCTAssertEqual(cards.first?.transactions.map(\.id), [ids.txID])
    }

    func testTheAppsOpenPathDoesNotQuarantineAnUnversionedStore() throws {
        let url = dir.appendingPathComponent("default.store")
        _ = try writeUnversionedStore(at: url)

        let schema = Schema(versionedSchema: DiPoSchemaCurrent.self)
        let container = StoreRecovery.openContainer(schema: schema,
                                                    config: ModelConfiguration(schema: schema, url: url),
                                                    migrationPlan: DiPoMigrationPlan.self)
        XCTAssertNil(StoreRecovery.pendingNotice)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<BankCard>()).count, 1)
    }

    /// A store the plan doesn't list (here: the full schema, opened with a plan
    /// that only knows a one-model schema) must not go to quarantine while
    /// SwiftData's own lightweight migration can still open it — and whatever
    /// happens, the bytes as they were must survive somewhere.
    func testStoreThePlanDoesNotListIsCopiedThenOpenedWithoutThePlan() throws {
        let url = dir.appendingPathComponent("default.store")
        _ = try writeUnversionedStore(at: url)
        let original = try Data(contentsOf: url)

        let schema = Schema(versionedSchema: OneModelSchema.self)
        let container = StoreRecovery.openContainer(schema: schema,
                                                    config: ModelConfiguration(schema: schema, url: url),
                                                    migrationPlan: OneModelPlan.self)
        XCTAssertNil(StoreRecovery.pendingNotice, "should not have quarantined")
        XCTAssertNoThrow(try ModelContext(container).fetch(FetchDescriptor<DayCheckIn>()))

        // If SwiftData refused the plan (the case this path exists for), the
        // copy taken before the unplanned migration holds the original bytes.
        let root = dir.appendingPathComponent("StoreQuarantine")
        let copies = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for copy in copies {
            XCTAssertTrue(copy.hasSuffix("-before-unplanned-migration"))
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(copy).appendingPathComponent("default.store")),
                           original)
        }
    }

    func testPlanEndsAtTheCurrentVersionAndOnlyMovesForward() {
        func key(_ v: Schema.Version) -> Int { v.major * 1_000_000 + v.minor * 1_000 + v.patch }
        let versions = DiPoMigrationPlan.schemas.map { key($0.versionIdentifier) }
        XCTAssertEqual(versions.last, key(DiPoSchemaCurrent.versionIdentifier))
        XCTAssertEqual(versions, versions.sorted())
        XCTAssertEqual(Set(versions).count, versions.count)
    }
}

/// A plan that knows only a one-model schema, so a full store is unknown to it.
nonisolated private enum OneModelSchema: VersionedSchema {
    static let versionIdentifier = Schema.Version(9, 0, 0)
    static var models: [any PersistentModel.Type] { [DayCheckIn.self] }
}

nonisolated private enum OneModelPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [OneModelSchema.self] }
    static var stages: [MigrationStage] { [] }
}
