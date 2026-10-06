import XCTest
import SwiftData
@testable import DiPo

/// The rollup brought up to date one day at a time must equal a full rebuild.
@MainActor
final class RollupIncrementalTests: XCTestCase {

    private func tx(_ amount: Double, _ date: Date, _ cat: TxCategory = .food) -> TxRecord {
        TxRecord(name: "x", date: date, amount: amount, type: "tx.type.purchase", icon: "circle",
                 iconBgHex: cat.iconBg, category: cat, currency: "IDR")
    }

    func testAddingAndDeletingMatchesAFullRebuild() throws {
        let schema = Schema(versionedSchema: DiPoSchemaCurrent.self)
        let container = try ModelContainer(for: schema,
                                           configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        let ctx = container.mainContext
        let card = BankCard(holderName: "Bank", cardNumber: "5221845086220969", balance: 0,
                            expireDate: "11/29", gradientStart: "#000000", gradientEnd: "#111111",
                            sortOrder: 0, currency: "IDR")
        ctx.insert(card)
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now).addingTimeInterval(12 * 3_600)
        card.transactions = (0..<40).map { tx(-Double(1_000 * ($0 + 1)), cal.date(byAdding: .day, value: -$0 / 2, to: today)!) }
        try ctx.save()

        let store = RollupStore.shared
        store.rebuild(context: ctx)

        // Add one today and one twenty days back, delete one from day 5.
        card.transactions.append(tx(-50_000, today))
        card.transactions.append(tx(3_000_000, cal.date(byAdding: .day, value: -20, to: today)!, .salary))
        let victim = card.transactions.first { cal.isDate($0.date, inSameDayAs: cal.date(byAdding: .day, value: -5, to: today)!) }!
        card.transactions.removeAll { $0 === victim }
        ctx.delete(victim)
        try ctx.save()

        let count = card.transactions.count
        let incremental = store.rebuildIfStale(context: ctx, txCount: count)
        // What the incremental pass saved, before a full rebuild rewrites it.
        let saved = try ctx.fetch(FetchDescriptor<DailyRollup>()).map { $0.toBucket() }
            .sorted { $0.dayStart < $1.dayStart }
        let full = store.rebuild(context: ctx).sorted { $0.dayStart < $1.dayStart }
        XCTAssertEqual(incremental.count, full.count)
        XCTAssertEqual(incremental, full)
        XCTAssertEqual(saved, full)
    }
}
