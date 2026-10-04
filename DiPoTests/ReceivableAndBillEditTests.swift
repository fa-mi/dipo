import XCTest
import SwiftData
@testable import DiPo

/// Money lent out, and a monthly bill whose amount changes after this month's
/// charge was already posted.
@MainActor
final class ReceivableAndBillEditTests: XCTestCase {

    private var container: ModelContainer!

    override func setUpWithError() throws {
        let schema = Schema(versionedSchema: DiPoSchemaCurrent.self)
        container = try ModelContainer(for: schema,
                                       configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    }

    private func tx(_ amount: Double, currency: String = "IDR") -> TxRecord {
        let t = TxRecord(name: "x", date: .now, amount: amount, type: "tx.type.purchase", icon: "X",
                         iconBgHex: "#000000", category: .other, currency: currency)
        container.mainContext.insert(t)
        return t
    }

    func testTheLoanItselfIsNotARepayment() {
        let r = Receivable(personName: "Mom", amount: 10_000_000, currency: "IDR")
        container.mainContext.insert(r)
        let lent = tx(-10_000_000)
        lent.linkedReceivableID = r.id.uuidString
        let back = tx(5_000_000)
        back.linkedReceivableID = r.id.uuidString
        XCTAssertEqual(r.repaidAmount(from: [lent]), 0)
        XCTAssertEqual(r.repaidAmount(from: [lent, back]), 5_000_000)
        XCTAssertEqual(r.outstanding(from: [lent, back]), 5_000_000)
        XCTAssertEqual(r.progress(from: [lent, back]), 0.5, accuracy: 1e-9)
    }

    func testRepricingAPostedChargeKeepsItsFrozenRate() {
        // Same currency: the new amount, as a debit.
        let idr = tx(-350_000)
        RecurringHistory.reprice(idr, to: 400_000, billCurrency: "IDR")
        XCTAssertEqual(idr.amount, -400_000)

        // A $20 subscription paid from a rupiah card at Rp 16.000 = $1.
        let usd = tx(-320_000)
        usd.fxOriginalAmount = -20
        usd.fxOriginalCurrency = "USD"
        usd.fxRate = 16_000
        RecurringHistory.reprice(usd, to: 25, billCurrency: "USD")
        XCTAssertEqual(usd.fxOriginalAmount, -25)
        XCTAssertEqual(usd.amount, -400_000, accuracy: 0.01)
    }

    func testNewStringsInBothLanguages() {
        for key in ["receivable.detail.history", "receivable.detail.no_history", "receivable.detail.repayment",
                    "recurring.reprice_title", "recurring.reprice_msg", "recurring.reprice_also",
                    "recurring.reprice_next_only"] {
            XCTAssertNotEqual(loc(key), key, key)
        }
    }
}
