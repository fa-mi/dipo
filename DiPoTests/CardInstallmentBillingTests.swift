import XCTest
import SwiftData
@testable import DiPo

/// A billed instalment goes onto the bill, and only a payment takes it off.
///
/// Fahmi's Tokopedia CC (17 Oct): limit Rp 40 jt, Rp 5.750.000 owed besides,
/// and an iPad on 12× at 0% — Rp 10.250.000, Rp 854.167 a month. The
/// instalment used to leave "locked" by the calendar alone, as though paid,
/// and the payment that really covered it came off the rest of the balance
/// too: Rp 854.167 short for every month paid.
@MainActor
final class CardInstallmentBillingTests: XCTestCase {

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

    private func tokopediaCC() -> BankCard {
        let c = BankCard(holderName: "Tokopedia CC", cardNumber: "5221845086220969", balance: 0, expireDate: "11/29",
                         gradientStart: "#000000", gradientEnd: "#111111", sortOrder: 0, currency: "IDR")
        c.isCreditCard = true
        c.creditLimit = 40_000_000
        c.openingOwed = 5_750_000
        c.creditSince = .distantPast
        context.insert(c)
        return c
    }

    @discardableResult
    private func iPad(on card: BankCard, start: Date, recorded: Date? = nil) -> CardInstallment {
        let i = CardInstallment(cardID: card.id, merchant: "iPad Air M3", totalAmount: 10_250_000, tenorMonths: 12,
                                startDate: start, currency: "IDR")
        i.createdAt = recorded ?? start
        context.insert(i)
        return i
    }

    private func pay(_ amount: Double, on card: BankCard, at date: Date) {
        let t = TxRecord(name: "Payment received — Tokopedia CC", date: date, amount: amount, type: "tx.type.income",
                         icon: "CC", iconBgHex: TxCategory.other.iconBg, category: .other, currency: "IDR",
                         notes: "tx.note.cc_payment", subtype: .transfer)
        context.insert(t)
        card.transactions.append(t)
    }

    private let monthly = 10_250_000.0 / 12

    // MARK: The bill

    func testBeforeTheFirstBillTheWholeInstalmentIsLocked() {
        let card = tokopediaCC()
        let ipad = iPad(on: card, start: day(10, 9))
        let b = card.bill([ipad], asOf: day(10, 20))
        XCTAssertEqual(b.installmentDue, 0)
        XCTAssertEqual(b.revolving, 5_750_000, accuracy: 0.5)
        XCTAssertEqual(b.locked, 10_250_000, accuracy: 0.5)
        XCTAssertEqual(b.total, 16_000_000, accuracy: 0.5)
    }

    /// The month turns: Rp 854.167 moves from locked onto the bill, and the
    /// total stays where it was until something is paid.
    func testABilledInstalmentMovesOntoTheBillAndTheTotalHolds() {
        let card = tokopediaCC()
        let ipad = iPad(on: card, start: day(10, 9))
        let b = card.bill([ipad], asOf: day(11, 12))
        XCTAssertEqual(b.installmentDue, monthly, accuracy: 0.5)
        XCTAssertEqual(b.locked, 10_250_000 - monthly, accuracy: 0.5)
        XCTAssertEqual(b.revolving, 5_750_000, accuracy: 0.5)
        XCTAssertEqual(b.bill, 6_604_167, accuracy: 0.5)
        XCTAssertEqual(b.total, 16_000_000, accuracy: 0.5, "nothing paid, nothing less owed")
        XCTAssertEqual(card.totalOwed([ipad]), card.bill([ipad]).total, accuracy: 0.5)
    }

    /// Paying the instalment settles the instalment — and only it. The rest of
    /// the balance used to drop by the same Rp 854.167 as well.
    func testPayingTheInstalmentLeavesTheRestOfTheBalanceAlone() {
        let card = tokopediaCC()
        let ipad = iPad(on: card, start: day(10, 9))
        pay(854_167, on: card, at: day(11, 13))
        let b = card.bill([ipad], asOf: day(11, 14))
        XCTAssertEqual(b.installmentDue, 0)
        XCTAssertEqual(b.revolving, 5_750_000, accuracy: 1, "not Rp 4.895.833")
        XCTAssertEqual(b.total, 15_145_833, accuracy: 1)
        XCTAssertEqual(card.creditLimit - b.total, 24_854_167, accuracy: 1, "the limit comes back by what was paid")
    }

    func testAPaymentSettlesTheInstalmentFirstThenTheRest() {
        let card = tokopediaCC()
        let ipad = iPad(on: card, start: day(10, 9))
        pay(1_000_000, on: card, at: day(11, 13))
        let b = card.bill([ipad], asOf: day(11, 14))
        XCTAssertEqual(b.installmentDue, 0)
        XCTAssertEqual(b.revolving, 5_750_000 - (1_000_000 - monthly), accuracy: 0.5)
    }

    func testPayingTheWholeBillLeavesOnlyTheLockedPrincipal() {
        let card = tokopediaCC()
        let ipad = iPad(on: card, start: day(10, 9))
        pay(6_604_167, on: card, at: day(11, 13))
        let b = card.bill([ipad], asOf: day(11, 14))
        XCTAssertEqual(b.bill, 0, accuracy: 0.5)
        XCTAssertEqual(b.total, 10_250_000 - monthly, accuracy: 0.5)
    }

    func testAnUnpaidInstalmentStaysOnTheBillMonthAfterMonth() {
        let card = tokopediaCC()
        let ipad = iPad(on: card, start: day(10, 9))
        let b = card.bill([ipad], asOf: cal.date(from: DateComponents(year: 2027, month: 1, day: 12, hour: 12))!)
        XCTAssertEqual(b.installmentDue, 3 * monthly, accuracy: 0.5)
        XCTAssertEqual(b.total, 16_000_000, accuracy: 0.5)
    }

    /// Months billed before DiPo knew of the instalment are already in the
    /// owed figure the user typed in, paid or not.
    func testMonthsBilledBeforeTheInstalmentWasRecordedAreNotAddedAgain() {
        let card = tokopediaCC()
        let ipad = iPad(on: card, start: day(7, 9), recorded: day(10, 9))
        let b = card.bill([ipad], asOf: day(10, 20))
        XCTAssertEqual(b.installmentDue, 0)
        XCTAssertEqual(b.locked, 10_250_000 * 9 / 12, accuracy: 0.5)
        XCTAssertEqual(b.total, 5_750_000 + 10_250_000 * 9 / 12, accuracy: 0.5)
    }

    /// Editing the card's owed figure re-bases it: what was billed before is
    /// in the new figure.
    func testMonthsBilledBeforeTheOwedFigureWasLastSetAreNotAddedAgain() {
        let card = tokopediaCC()
        let ipad = iPad(on: card, start: day(10, 9))
        card.openingOwed = 6_604_167
        card.creditSince = day(11, 20)
        let b = card.bill([ipad], asOf: day(11, 25))
        XCTAssertEqual(b.installmentDue, 0)
        XCTAssertEqual(b.bill, 6_604_167, accuracy: 0.5)
    }

    // MARK: Paying more than the bill

    private func buy(_ amount: Double, on card: BankCard, at date: Date) {
        let t = TxRecord(name: "Belanja", date: date, amount: -amount, type: "tx.type.purchase", icon: "BE",
                         iconBgHex: TxCategory.shopping.iconBg, category: .shopping, currency: "IDR")
        context.insert(t)
        card.transactions.append(t)
    }

    /// Fahmi's card on 27 Oct, as the pay screen showed it: Rp 14.699.000
    /// used, Rp 10.250.000 of it the iPad not billed yet, Rp 199.000 of
    /// purchases and Rp 4.250.000 older on the bill.
    private func cardBeforeThePayment() -> (BankCard, CardInstallment) {
        let card = tokopediaCC()
        let ipad = iPad(on: card, start: day(10, 9))
        buy(250_000, on: card, at: day(10, 15))
        pay(250_000, on: card, at: day(10, 17))
        pay(1_500_000, on: card, at: day(10, 23))
        buy(199_000, on: card, at: day(10, 27))
        return (card, ipad)
    }

    /// He paid Rp 4.699.000, Rp 250.000 more than the bill. The pay screen
    /// said the extra was kept on the card, and the card then read
    /// Rp 10.250.000 owed: the extra had been dropped from the total.
    func testPayingMoreThanTheBillComesOffTheTotal() {
        let (card, ipad) = cardBeforeThePayment()
        let before = card.bill([ipad], asOf: day(10, 27))
        XCTAssertEqual(before.total, 14_699_000, accuracy: 0.5)
        let split = CardPaymentDebt.split(payment: 4_699_000, on: card, installments: [ipad], asOf: day(10, 27))
        XCTAssertEqual(split.purchases, 199_000, accuracy: 0.5)
        XCTAssertEqual(split.debt, 4_250_000, accuracy: 0.5)
        XCTAssertEqual(split.extra, 250_000, accuracy: 0.5)

        pay(4_699_000, on: card, at: day(10, 27).addingTimeInterval(60))
        let after = card.bill([ipad], asOf: day(10, 28))
        XCTAssertEqual(after.bill, 0, accuracy: 0.5)
        XCTAssertEqual(after.credit, 250_000, accuracy: 0.5)
        XCTAssertEqual(after.locked, 10_250_000, accuracy: 0.5)
        XCTAssertEqual(after.total, 10_000_000, accuracy: 0.5, "Rp 14.699.000 less the Rp 4.699.000 paid, not Rp 10.250.000")
        XCTAssertEqual(card.creditLimit - after.total, 30_000_000, accuracy: 0.5, "the limit comes back by all of it")
    }

    /// The extra comes off the next bill: when the iPad is billed, Rp 250.000
    /// of its Rp 854.167 is paid already, and the total holds.
    func testTheExtraComesOffTheNextBill() {
        let (card, ipad) = cardBeforeThePayment()
        pay(4_699_000, on: card, at: day(10, 27).addingTimeInterval(60))
        let next = card.bill([ipad], asOf: day(11, 12))
        XCTAssertEqual(next.credit, 0, accuracy: 0.5)
        XCTAssertEqual(next.bill, monthly - 250_000, accuracy: 0.5)
        XCTAssertEqual(next.total, 10_000_000, accuracy: 0.5)
    }

    /// More paid than everything owed, instalments included: nothing is owed,
    /// never less than nothing.
    func testACreditBeyondEverythingOwedLeavesNothingOwed() {
        let card = tokopediaCC()
        pay(6_000_000, on: card, at: day(10, 17))
        let b = card.bill([], asOf: day(10, 18))
        XCTAssertEqual(b.credit, 250_000, accuracy: 0.5)
        XCTAssertEqual(b.total, 0)
        XCTAssertEqual(card.creditLimit - b.total, 40_000_000, accuracy: 0.5)
    }

    func testTheOverpaidWordsKeepTheirAmounts() {
        for language in [LanguageManager.Language.english, .indonesian] {
            LanguageManager.shared.withLanguage(language) {
                let both = String(format: loc("cc.unbilled_less_credit"), "Rp 10.250.000", "Rp 250.000")
                XCTAssertTrue(both.contains("Rp 10.250.000") && both.contains("Rp 250.000"), both)
                XCTAssertTrue(String(format: loc("cc.credit_on_card"), "Rp 250.000").contains("Rp 250.000"))
            }
        }
    }

    func testWithoutInstalmentsTheBillIsTheLoggedBalance() {
        let card = tokopediaCC()
        pay(250_000, on: card, at: day(10, 17))
        let b = card.bill([], asOf: day(10, 18))
        XCTAssertEqual(b, CardBill(installmentDue: 0, revolving: 5_500_000, locked: 0))
    }

    // MARK: From the card's own store, as the screens read it

    /// Dated from today, since these read the calendar themselves.
    private func billedOnceAgo(_ card: BankCard) {
        let start = cal.date(byAdding: .day, value: -2, to: cal.date(byAdding: .month, value: -1, to: .now)!)!
        iPad(on: card, start: start)
    }

    func testTheOwedFigureEveryScreenShowsIncludesTheBilledInstalment() {
        let card = tokopediaCC()
        billedOnceAgo(card)
        XCTAssertEqual(card.storedInstallments.count, 1)
        XCTAssertEqual(card.owedBalance(), 5_750_000 + monthly, accuracy: 0.5)
        XCTAssertEqual(card.totalOwed(card.storedInstallments), 16_000_000, accuracy: 0.5)
    }

    /// The balance charged interest is the carried one — the instalment is
    /// neither carried nor charged, and paying it does not shrink the carried
    /// balance.
    func testABilledInstalmentIsNotCarriedAndPayingItKeepsTheCarriedBalance() {
        let card = tokopediaCC()
        billedOnceAgo(card)
        let thisMonth = cal.date(from: cal.dateComponents([.year, .month], from: .now))!
        let lastMonth = cal.date(byAdding: .month, value: -1, to: thisMonth)!
        XCTAssertEqual(ObligationLoad.carried(on: card, since: lastMonth), 5_750_000, accuracy: 0.5)
        pay(854_167, on: card, at: cal.date(byAdding: .minute, value: -5, to: .now)!)
        XCTAssertEqual(ObligationLoad.carried(on: card, since: lastMonth), 5_750_000, accuracy: 1)
        XCTAssertEqual(ObligationLoad.cardCarried(cards: [card], currency: "IDR"), 5_750_000, accuracy: 1)
    }

    // MARK: Recording a payment

    /// The instalment part of a payment is a debt payment: the iPad was never
    /// counted as spending when it was bought, so this is where it is counted.
    func testTheInstalmentPartOfAPaymentIsADebtPayment() {
        // Rp 5.750.000 besides the instalment: Rp 470.000 bought this month,
        // Rp 5.280.000 older.
        XCTAssertEqual(CardPaymentDebt.split(payment: 854_167, installmentDue: monthly,
                                             unpaidPurchases: 470_000, olderBalance: 5_280_000).debt,
                       854_167, accuracy: 0.5)
        // The whole bill: the instalment and the older balance are debt; the
        // Rp 470.000 bought this month is the transfer.
        let whole = CardPaymentDebt.split(payment: 6_604_167, installmentDue: monthly,
                                          unpaidPurchases: 470_000, olderBalance: 5_280_000)
        XCTAssertEqual(whole.debt, monthly + 5_280_000, accuracy: 0.5)
        XCTAssertEqual(whole.purchases, 470_000, accuracy: 1)
        // Without instalments the purchases are settled first: of Rp 2 jt,
        // Rp 470.000 pays for them and Rp 1.530.000 comes off the older balance.
        let part = CardPaymentDebt.split(payment: 2_000_000, installmentDue: 0,
                                         unpaidPurchases: 470_000, olderBalance: 5_280_000)
        XCTAssertEqual(part.purchases, 470_000, accuracy: 0.5)
        XCTAssertEqual(part.debt, 1_530_000, accuracy: 0.5)
    }

    /// On the card's own ledger: a payment fills the billed instalment first,
    /// then this month's purchase, and only then the older balance.
    func testOnTheLedgerAPaymentFillsTheInstalmentThenPurchases() {
        let card = tokopediaCC()
        let ipad = iPad(on: card, start: day(10, 9))
        let shoes = TxRecord(name: "Sepatu", date: day(11, 5), amount: -470_000, type: "tx.type.purchase",
                             icon: "SE", iconBgHex: TxCategory.shopping.iconBg, category: .shopping, currency: "IDR")
        context.insert(shoes)
        card.transactions.append(shoes)
        XCTAssertEqual(CardPaymentDebt.unpaidPurchases(on: card, installments: [ipad], asOf: day(11, 12)),
                       470_000, accuracy: 0.5)
        let s = CardPaymentDebt.split(payment: 1_500_000, on: card, installments: [ipad], asOf: day(11, 12))
        XCTAssertEqual(s.purchases, 470_000, accuracy: 0.5)
        XCTAssertEqual(s.debt, 1_500_000 - 470_000, accuracy: 0.5, "the instalment and Rp 175.833 of the older balance")

        pay(1_500_000, on: card, at: day(11, 13))
        XCTAssertEqual(CardPaymentDebt.unpaidPurchases(on: card, installments: [ipad], asOf: day(11, 14)), 0)
        let b = card.bill([ipad], asOf: day(11, 14))
        XCTAssertEqual(b.installmentDue, 0)
        XCTAssertEqual(b.revolving, 5_750_000 + 470_000 - (1_500_000 - monthly), accuracy: 0.5)
    }

    // MARK: Words

    func testTheCounterSaysBilledNotPaid() {
        LanguageManager.shared.withLanguage(.english) {
            XCTAssertEqual(String(format: loc("inst.progress"), 1, 12), "1 of 12 billed")
            XCTAssertNotEqual(loc("inst.due"), "inst.due")
        }
        LanguageManager.shared.withLanguage(.indonesian) {
            XCTAssertEqual(String(format: loc("inst.progress"), 1, 12), "1 dari 12 sudah ditagih")
            XCTAssertNotEqual(loc("inst.due"), "inst.due")
            XCTAssertTrue(loc("cc.pay_hint").contains("cicilan"))
        }
    }
}
