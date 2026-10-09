import XCTest
import SwiftData
@testable import DiPo

/// A credit card's own transactions, under the card on Debts & Credits.
@MainActor
final class CardHistoryTests: XCTestCase {

    private var container: ModelContainer!

    override func setUpWithError() throws {
        let schema = Schema(versionedSchema: DiPoSchemaCurrent.self)
        container = try ModelContainer(for: schema,
                                       configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    }

    private func tx(_ name: String, _ amount: Double, _ date: Date) -> TxRecord {
        let t = TxRecord(name: name, date: date, amount: amount, type: "tx.type.purchase", icon: "X",
                         iconBgHex: "#000000", category: .shopping, currency: "IDR")
        container.mainContext.insert(t)
        return t
    }

    private func at(_ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: m, day: d, hour: h))!
    }

    func testNewestFirstGroupedByDay() {
        let now = at(10, 9, 16)
        let rows = [tx("Payment received", 1_882_381, at(10, 8)),
                    tx("Sepatu", -470_000, at(10, 9, 15)),
                    tx("Payment received", 2_000_000, at(10, 4)),
                    tx("Kopi", -30_000, at(10, 9, 9))]
        let days = CardHistory.days(rows, now: now)
        XCTAssertEqual(days.map { $0.rows.map(\.name) }, [["Sepatu", "Kopi"], ["Payment received"], ["Payment received"]])
        XCTAssertEqual(days[0].label, loc("common.today"))
        XCTAssertEqual(days[1].label, loc("common.yesterday"))
    }

    /// Under the card: only the latest three, so a purchase just logged shows
    /// first.
    func testTheCardShowsOnlyTheLatestFew() {
        let now = at(10, 9, 16)
        let rows = (1...6).map { tx("t\($0)", -1_000, at(10, $0)) }
        let days = CardHistory.days(rows, limit: CardHistorySection.preview, now: now)
        XCTAssertEqual(days.flatMap(\.rows).map(\.name), ["t6", "t5", "t4"])
    }

    func testStringsExist() {
        for key in ["cc.history", "cc.history_all", "cc.history_empty", "cc.history_title"] {
            XCTAssertNotEqual(loc(key), key, "missing \(key)")
        }
    }
}
