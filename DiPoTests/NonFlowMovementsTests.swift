import XCTest
import SwiftData
@testable import DiPo

/// Transfers listed beside the Statistics breakdown: shown, never totalled.
@MainActor
final class NonFlowMovementsTests: XCTestCase {

    private var container: ModelContainer!

    override func setUpWithError() throws {
        let schema = Schema(versionedSchema: DiPoSchemaCurrent.self)
        container = try ModelContainer(for: schema,
                                       configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    }

    private func tx(_ name: String, _ amount: Double, icon: String = "X", notes: String = "",
                    subtype: TxSubtype = .transfer) -> TxRecord {
        let t = TxRecord(name: name, date: .now, amount: amount, type: "tx.type.purchase", icon: icon,
                         iconBgHex: "#000000", category: .other, currency: "IDR", notes: notes, subtype: subtype)
        container.mainContext.insert(t)
        return t
    }

    func testRepaymentsShowAsMoneyInAndOwnAccountMovesDoNot() {
        let txs = [
            tx("Repaid by Mom", 5_000_000, notes: "tx.note.receivable_repaid"),
            tx("Repaid by Mom", 1_000_000, notes: "tx.note.receivable_repaid"),
            tx("From BRI", 2_000_000, icon: "⇄"),                                  // card-to-card
            tx("Payment from BCA", 2_000_000, icon: "CC", notes: "tx.note.cc_payment"),  // the card's side
            tx("Salary", 10_000_000, subtype: .normal),                             // real income, not here
        ]
        let rows = NonFlowMovements.rows(txs, incoming: true, amount: { $0.amount })
        XCTAssertEqual(rows, [.init(label: "Repaid by Mom", amount: 6_000_000, count: 2)])
    }

    func testCardBillAndLendingShowAsMoneyOut() {
        let txs = [
            tx("Pay Tokopedia Card", -2_000_000, icon: "CC", notes: "tx.note.cc_payment"),
            tx("Lent to Dad", -500_000, notes: "tx.note.receivable_lent"),
            tx("To BRI", -1_000_000, icon: "⇄"),
            tx("Food", -75_000, subtype: .normal),
        ]
        let rows = NonFlowMovements.rows(txs, incoming: false, amount: { $0.amount })
        XCTAssertEqual(rows.map(\.label), [loc("stats.nonflow.cc_payment"), "Lent to Dad"])
        XCTAssertEqual(rows.map(\.amount), [2_000_000, 500_000])
    }

    func testStringsInBothLanguages() {
        for key in ["stats.nonflow.in_title", "stats.nonflow.in_sub", "stats.nonflow.out_title",
                    "stats.nonflow.out_sub", "stats.nonflow.cc_payment", "stats.nonflow.more"] {
            XCTAssertNotEqual(loc(key), key, key)
        }
    }
}
