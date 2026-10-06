import XCTest
@testable import DiPo

/// A credit-card payment pays off debt for the part covering a balance
/// carried from before, and settles a bill for the part covering recent
/// purchases.
@MainActor
final class CardPaymentDebtTests: XCTestCase {

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Jakarta")!
        return c
    }
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }
    private func tx(_ amount: Double, _ on: Date, subtype: TxSubtype = .normal) -> TxRecord {
        TxRecord(name: "x", date: on, amount: amount, type: "tx.type.purchase", icon: "circle",
                 iconBgHex: TxCategory.shopping.iconBg, category: .shopping, currency: "IDR",
                 subtype: subtype)
    }
    private let same = { (t: TxRecord) in t.amount }

    /// The case from the backup: Rp 11,4 jt opening balance, Rp 1 jt paid in
    /// August, no purchases logged — the Rp 2 jt paid in October is all debt.
    func testPayingOffAnOpeningBalanceIsAllDebt() {
        let txs = [tx(1_000_000, date(2026, 8, 20), subtype: .transfer)]
        let pay = date(2026, 10, 4)
        let owed = CardPaymentDebt.owedBefore(openingOwed: 11_443_509, since: nil, transactions: txs,
                                              date: pay, convert: same)
        XCTAssertEqual(owed, 10_443_509, accuracy: 0.01)
        let recent = CardPaymentDebt.recentCharges(transactions: txs, before: pay, convert: same, cal: cal)
        XCTAssertEqual(recent, 0)
        XCTAssertEqual(CardPaymentDebt.debtPortion(payment: 2_000_000, owedBefore: owed, recentCharges: recent),
                       2_000_000, accuracy: 0.01)
    }

    /// Paying exactly last month's and this month's purchases is no debt at all.
    func testPayingTheRecentBillIsNoDebt() {
        let pay = date(2026, 10, 4)
        let txs = [tx(-1_200_000, date(2026, 9, 10)), tx(-300_000, date(2026, 10, 2))]
        let owed = CardPaymentDebt.owedBefore(openingOwed: 0, since: nil, transactions: txs, date: pay, convert: same)
        let recent = CardPaymentDebt.recentCharges(transactions: txs, before: pay, convert: same, cal: cal)
        XCTAssertEqual(recent, 1_500_000, accuracy: 0.01)
        XCTAssertEqual(CardPaymentDebt.debtPortion(payment: 1_500_000, owedBefore: owed, recentCharges: recent), 0)
    }

    /// Rp 5 jt owed, Rp 2 jt of it recent purchases: a Rp 4 jt payment is
    /// Rp 3 jt off the carried balance and Rp 1 jt towards the recent bill.
    func testAMixedPaymentIsSplit() {
        XCTAssertEqual(CardPaymentDebt.debtPortion(payment: 4_000_000, owedBefore: 5_000_000,
                                                   recentCharges: 2_000_000), 3_000_000, accuracy: 0.01)
        // Never more than was paid.
        XCTAssertEqual(CardPaymentDebt.debtPortion(payment: 500_000, owedBefore: 5_000_000,
                                                   recentCharges: 0), 500_000, accuracy: 0.01)
    }

    /// Purchases older than last month are carried, not recent.
    func testOnlyThisAndLastMonthCountAsRecent() {
        let pay = date(2026, 10, 4)
        let txs = [tx(-700_000, date(2026, 8, 30)), tx(-400_000, date(2026, 9, 1)),
                   tx(-50_000, date(2026, 10, 5))]   // after the payment: not part of it
        XCTAssertEqual(CardPaymentDebt.recentCharges(transactions: txs, before: pay, convert: same, cal: cal),
                       400_000, accuracy: 0.01)
    }

    func testHintInBothLanguages() {
        for lang in LanguageManager.Language.allCases {
            LanguageManager.shared.withLanguage(lang) {
                XCTAssertNotEqual(loc("cc.pay_hint"), "cc.pay_hint")
            }
        }
    }
}
