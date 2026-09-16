import XCTest
@testable import DiPo

/// The whole point of the rollup is to make Smart Budget fast WITHOUT moving a
/// number. This pins the rollup-backed `spent(in:buckets:)` to the existing
/// transaction-backed `spent(in:transactions:)`: same fixture, same figure.
///
/// The fixture is single-currency (IDR) on purpose, so neither path depends on
/// a live FX rate — a same-currency conversion is the identity on both sides —
/// which keeps the assertion deterministic without a network or the simulator.
final class SmartBudgetRollupTests: XCTestCase {

    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Jakarta")!
        return c
    }()

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: 10))!
    }

    func testBucketSpentEqualsTransactionSpent() {
        let sb = SmartBudgetManager.shared
        // Use a real category from the group so the test tracks the shipped
        // category map rather than hardcoding one that could be recategorised.
        guard let cat = sb.categories(for: .daily).first else {
            return XCTFail("no categories in .daily")
        }

        let monthStart = day(2026, 9, 1)
        let txs = [
            TxRecord(name: "Groceries", date: day(2026, 9, 3), amount: -100_000,
                     type: "tx.type.purchase", icon: "", iconBgHex: "", category: cat, currency: "IDR"),
            TxRecord(name: "Lunch", date: day(2026, 9, 10), amount: -50_000,
                     type: "tx.type.purchase", icon: "", iconBgHex: "", category: cat, currency: "IDR"),
            // A refund reverses part of the spend.
            TxRecord(name: "Return", date: day(2026, 9, 12), amount: 20_000,
                     type: "tx.type.purchase", icon: "", iconBgHex: "", category: cat, currency: "IDR",
                     subtype: .refund),
            // Before the window — must be excluded by BOTH paths.
            TxRecord(name: "Old", date: day(2026, 8, 20), amount: -9_999,
                     type: "tx.type.purchase", icon: "", iconBgHex: "", category: cat, currency: "IDR"),
        ]

        let fromTransactions = sb.spent(in: .daily, transactions: txs,
                                        targetCurrency: "IDR", periodStart: monthStart)

        let buckets = RollupEngine.daily(from: txs.map { TxFact($0, cardID: "CARD") }, calendar: cal)
        let fromBuckets = sb.spent(in: .daily, buckets: buckets, targetCurrency: "IDR",
                                   periodStart: monthStart, cardID: "CARD",
                                   convert: { amount, _, _ in amount })

        XCTAssertEqual(fromTransactions, fromBuckets, accuracy: 0.001)
        // And the value itself is the expected 100k + 50k − 20k refund.
        XCTAssertEqual(fromBuckets, 130_000, accuracy: 0.001)
    }

    /// Gross vs net: the Smart Budget VIEWS (overGroups/currentCycleSnapshot)
    /// exclude refunds via `amount < 0`, so `gross: true` must NOT subtract a
    /// refund, while the default (canonical) path does.
    func testGrossSpentDoesNotSubtractRefunds() {
        let sb = SmartBudgetManager.shared
        guard let cat = sb.categories(for: .daily).first else {
            return XCTFail("no categories in .daily")
        }
        let monthStart = day(2026, 9, 1)
        let txs = [
            TxRecord(name: "Buy", date: day(2026, 9, 3), amount: -100_000,
                     type: "tx.type.purchase", icon: "", iconBgHex: "", category: cat, currency: "IDR"),
            TxRecord(name: "Refund", date: day(2026, 9, 4), amount: 30_000,
                     type: "tx.type.purchase", icon: "", iconBgHex: "", category: cat, currency: "IDR",
                     subtype: .refund),
        ]
        let buckets = RollupEngine.daily(from: txs.map { TxFact($0, cardID: "C") }, calendar: cal)
        let net = sb.spent(in: .daily, buckets: buckets, targetCurrency: "IDR",
                           periodStart: monthStart, cardID: "C", gross: false, convert: { v, _, _ in v })
        let gross = sb.spent(in: .daily, buckets: buckets, targetCurrency: "IDR",
                             periodStart: monthStart, cardID: "C", gross: true, convert: { v, _, _ in v })
        XCTAssertEqual(net, 70_000, accuracy: 0.001)     // 100k − 30k refund (canonical)
        XCTAssertEqual(gross, 100_000, accuracy: 0.001)  // refund not netted (the views' convention)
    }

    /// A different card's spend must never leak into this card's figure.
    func testBucketSpentIsScopedToTheCard() {
        let sb = SmartBudgetManager.shared
        guard let cat = sb.categories(for: .daily).first else {
            return XCTFail("no categories in .daily")
        }
        let monthStart = day(2026, 9, 1)
        let txsA = [TxRecord(name: "A", date: day(2026, 9, 5), amount: -40_000,
                             type: "tx.type.purchase", icon: "", iconBgHex: "", category: cat, currency: "IDR")]
        let txsB = [TxRecord(name: "B", date: day(2026, 9, 5), amount: -1_000_000,
                             type: "tx.type.purchase", icon: "", iconBgHex: "", category: cat, currency: "IDR")]
        let facts = txsA.map { TxFact($0, cardID: "A") } + txsB.map { TxFact($0, cardID: "B") }
        let buckets = RollupEngine.daily(from: facts, calendar: cal)

        let a = sb.spent(in: .daily, buckets: buckets, targetCurrency: "IDR",
                         periodStart: monthStart, cardID: "A", convert: { v, _, _ in v })
        XCTAssertEqual(a, 40_000, accuracy: 0.001)   // not the 1,000,000 on card B
    }
}
