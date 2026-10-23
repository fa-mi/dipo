import XCTest
import SwiftData
@testable import DiPo

/// A credit-card payment settles billed instalments first, then purchases
/// logged in DiPo, then the older balance. Purchases were counted as spending
/// when they were made, so the part paying them is a transfer; instalments and
/// the older balance never were, so that part is a debt payment.
@MainActor
final class CardPaymentDebtTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }
    private let cal = Calendar.current

    override func setUpWithError() throws {
        let schema = Schema(versionedSchema: DiPoSchemaCurrent.self)
        container = try ModelContainer(for: schema,
                                       configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    }

    private func day(_ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: 2026, month: m, day: d, hour: 12))!
    }

    private func creditCard(owed: Double) -> BankCard {
        let c = BankCard(holderName: "Tokopedia CC", cardNumber: "5221845086220969", balance: 0, expireDate: "11/29",
                         gradientStart: "#000000", gradientEnd: "#111111", sortOrder: 0, currency: "IDR")
        c.isCreditCard = true
        c.creditLimit = 40_000_000
        c.openingOwed = owed
        c.creditSince = .distantPast
        context.insert(c)
        return c
    }

    private func add(_ amount: Double, _ subtype: TxSubtype, on card: BankCard, at date: Date) {
        let t = TxRecord(name: amount < 0 ? "Belanja" : "Payment received", date: date, amount: amount,
                         type: amount < 0 ? "tx.type.purchase" : "tx.type.income", icon: "CC",
                         iconBgHex: TxCategory.shopping.iconBg, category: amount < 0 ? .shopping : .other,
                         currency: "IDR", notes: subtype == .transfer ? "tx.note.cc_payment" : "",
                         subtype: subtype)
        context.insert(t)
        card.transactions.append(t)
    }
    private func buy(_ amount: Double, on card: BankCard, at date: Date) { add(-amount, .normal, on: card, at: date) }
    private func pay(_ amount: Double, on card: BankCard, at date: Date) { add(amount, .transfer, on: card, at: date) }

    private func split(_ payment: Double, on card: BankCard, at date: Date) -> CardPaymentDebt.Split {
        CardPaymentDebt.split(payment: payment, on: card, installments: [], asOf: date)
    }

    /// The case from the backup: Rp 11,4 jt opening balance, Rp 1 jt paid in
    /// August, no purchases logged — the Rp 2 jt paid in October is all debt.
    func testPayingOffAnOpeningBalanceIsAllDebt() {
        let card = creditCard(owed: 11_443_509)
        pay(1_000_000, on: card, at: day(8, 20))
        let s = split(2_000_000, on: card, at: day(10, 4))
        XCTAssertEqual(s.debt, 2_000_000, accuracy: 0.01)
        XCTAssertEqual(s.purchases, 0)
    }

    /// Paying for the purchases on the card is no debt at all.
    func testPayingForPurchasesIsNoDebt() {
        let card = creditCard(owed: 0)
        buy(1_200_000, on: card, at: day(9, 10))
        buy(300_000, on: card, at: day(10, 2))
        let s = split(1_500_000, on: card, at: day(10, 4))
        XCTAssertEqual(s.debt, 0)
        XCTAssertEqual(s.purchases, 1_500_000, accuracy: 0.01)
    }

    /// Fahmi's question: Rp 5.250.000 of older balance, Rp 500.000 bought
    /// this month, Rp 1.500.000 paid. The debt went down by Rp 1.000.000, and
    /// that is what Savings & debt counts — not Rp 1.500.000, which counted
    /// the Rp 500.000 a second time after Needs and Wants had it.
    func testPurchasesArePaidBeforeTheOlderBalance() {
        let card = creditCard(owed: 5_250_000)
        buy(500_000, on: card, at: day(10, 10))
        let s = split(1_500_000, on: card, at: day(10, 23))
        XCTAssertEqual(s.purchases, 500_000, accuracy: 0.01)
        XCTAssertEqual(s.debt, 1_000_000, accuracy: 0.01)
        XCTAssertEqual(s.extra, 0)
    }

    /// A purchase left on the card for months is still a purchase. Under the
    /// old rule it became "carried" after two months and its payment was a
    /// debt payment: counted in July as Wants and again in October.
    func testAPurchaseNeverTurnsIntoDebtByAgeing() {
        let card = creditCard(owed: 0)
        buy(2_000_000, on: card, at: day(7, 5))
        pay(500_000, on: card, at: day(8, 15))
        pay(500_000, on: card, at: day(9, 15))
        XCTAssertEqual(CardPaymentDebt.unpaidPurchases(on: card, installments: [], asOf: day(10, 1)),
                       1_000_000, accuracy: 0.01)
        let s = split(1_000_000, on: card, at: day(10, 15))
        XCTAssertEqual(s.debt, 0)
        XCTAssertEqual(s.purchases, 1_000_000, accuracy: 0.01)
    }

    /// A payment pays only what was bought before it: one made ahead of a
    /// purchase went to the older balance.
    func testAPaymentDoesNotPayForLaterPurchases() {
        let card = creditCard(owed: 3_000_000)
        pay(1_000_000, on: card, at: day(10, 1))
        buy(500_000, on: card, at: day(10, 5))
        XCTAssertEqual(CardPaymentDebt.unpaidPurchases(on: card, installments: [], asOf: day(10, 6)),
                       500_000, accuracy: 0.01)
        let s = split(1_000_000, on: card, at: day(10, 6))
        XCTAssertEqual(s.purchases, 500_000, accuracy: 0.01)
        XCTAssertEqual(s.debt, 500_000, accuracy: 0.01)
    }

    /// A refund takes its purchase back off the budget and off the card.
    func testARefundTakesItsPurchaseBack() {
        let card = creditCard(owed: 0)
        buy(1_000_000, on: card, at: day(10, 1))
        add(400_000, .refund, on: card, at: day(10, 3))
        XCTAssertEqual(CardPaymentDebt.unpaidPurchases(on: card, installments: [], asOf: day(10, 4)),
                       600_000, accuracy: 0.01)
    }

    /// Past everything owed, the rest stays on the card; the parts always add
    /// up to the payment.
    func testOverpayingLeavesExtraAndThePartsAddUp() {
        let card = creditCard(owed: 1_000_000)
        buy(500_000, on: card, at: day(10, 2))
        let s = split(2_000_000, on: card, at: day(10, 4))
        XCTAssertEqual(s.purchases, 500_000, accuracy: 0.01)
        XCTAssertEqual(s.debt, 1_000_000, accuracy: 0.01)
        XCTAssertEqual(s.extra, 500_000, accuracy: 0.01)
        for payment in [0.0, 250_000, 500_000, 1_499_999, 1_500_000, 9_000_000] {
            let p = split(payment, on: card, at: day(10, 4))
            XCTAssertEqual(p.debt + p.purchases + p.extra, payment, accuracy: 0.01)
        }
    }

    /// The balance charged interest follows the same order: once this
    /// month's purchases are paid, what is left is all older balance.
    func testTheCarriedBalanceIsWhatPaymentsLeaveOfTheOlderBalance() {
        let card = creditCard(owed: 5_250_000)
        let now = Date()
        let thisMonth = cal.date(from: cal.dateComponents([.year, .month], from: now))!
        let lastMonth = cal.date(byAdding: .month, value: -1, to: thisMonth)!
        buy(500_000, on: card, at: now.addingTimeInterval(-7_200))
        XCTAssertEqual(ObligationLoad.carried(on: card, since: lastMonth), 5_250_000, accuracy: 0.5,
                       "unpaid purchases this month are not carried")
        pay(1_500_000, on: card, at: now.addingTimeInterval(-3_600))
        XCTAssertEqual(ObligationLoad.carried(on: card, since: lastMonth), 4_250_000, accuracy: 0.5,
                       "the purchases were paid first; the older balance went down by Rp 1 jt, not Rp 1,5 jt")
    }

    func testHintInBothLanguages() {
        for lang in LanguageManager.Language.allCases {
            LanguageManager.shared.withLanguage(lang) {
                XCTAssertNotEqual(loc("cc.pay_hint"), "cc.pay_hint")
                XCTAssertFalse(loc("cc.pay_hint").contains("Invest & Debt"), "the group is Savings & debt now")
            }
        }
        LanguageManager.shared.withLanguage(.indonesian) {
            XCTAssertTrue(loc("cc.pay_hint").contains("Tabungan & cicilan"))
            XCTAssertEqual(loc("cc.owed"), "Tagihan sekarang")
            XCTAssertEqual(loc("cc.total_owed"), "Total utang")
        }
    }
}
