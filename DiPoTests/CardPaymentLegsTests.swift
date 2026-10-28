import XCTest
import SwiftData
@testable import DiPo

/// A card bill payment is one payment, however many rows it is written as.
///
/// Fahmi paid Rp 4.699.000 from BRI to his Tokopedia CC on 28 Oct. The cash
/// side was written in two parts — Rp 4.250.000 paying off debt, Rp 449.000
/// covering purchases and the extra — and Home listed "Tokopedia CC bill
/// payment" twice. Deleting the one that looked like a duplicate would have
/// left the other two saying money had moved.
@MainActor
final class CardPaymentLegsTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }
    private let paidAt = Date(timeIntervalSince1970: 1_793_141_460)   // 28 Oct 2026, 05:51 WIB

    override func setUpWithError() throws {
        let schema = Schema(versionedSchema: DiPoSchemaCurrent.self)
        container = try ModelContainer(for: schema,
                                       configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    }

    private func card(_ name: String, credit: Bool) -> BankCard {
        let c = BankCard(holderName: name, cardNumber: credit ? "5221845086220969" : "0123456789010969",
                         balance: 0, expireDate: "11/29", gradientStart: "#000000", gradientEnd: "#111111",
                         sortOrder: 0, currency: "IDR")
        c.isCreditCard = credit
        if credit {
            c.creditLimit = 40_000_000
            c.creditSince = .distantPast
        }
        context.insert(c)
        return c
    }

    @discardableResult
    private func row(_ name: String, _ amount: Double, at date: Date, on card: BankCard,
                     category: TxCategory = .other, notes: String = "",
                     subtype: TxSubtype = .normal) -> TxRecord {
        let t = TxRecord(name: name, date: date, amount: amount, type: "tx.type.purchase", icon: "CC",
                         iconBgHex: category.iconBg, category: category, currency: "IDR",
                         notes: notes, subtype: subtype)
        context.insert(t)
        card.transactions.append(t)
        return t
    }

    private struct Payment { let debt: TxRecord; let moved: TxRecord; let onCard: TxRecord }

    /// Written the way the pay screen writes it (CreditCardPaymentSheet).
    private func pay(debt: Double, moved: Double, from bri: BankCard, to cc: BankCard, at date: Date) -> Payment {
        let note = CardPaymentLegs.note
        let d = row("Tokopedia CC bill payment", -debt, at: date, on: bri, category: .debtPayment, notes: note)
        let m = row("Tokopedia CC bill payment", -moved, at: date, on: bri, notes: note, subtype: .transfer)
        let c = row("Payment received — Tokopedia CC", debt + moved, at: date.addingTimeInterval(0.001), on: cc,
                    notes: note, subtype: .transfer)
        return Payment(debt: d, moved: m, onCard: c)
    }

    private func ids(_ rows: [TxRecord]) -> Set<UUID> { Set(rows.map(\.id)) }

    // MARK: One row

    func testOnePaymentIsOneRowOnTheList() {
        let bri = card("BRI", credit: false), cc = card("Tokopedia CC", credit: true)
        let p = pay(debt: 4_250_000, moved: 449_000, from: bri, to: cc, at: paidAt)
        let salary = row("interim", 8_500_000, at: paidAt.addingTimeInterval(-7 * 60), on: bri, category: .salary)
        let gold = row("Gold invest", -200_000, at: paidAt.addingTimeInterval(-6 * 3600), on: bri, category: .investment)

        let rows = CardPaymentLegs.joined([p.moved, p.debt, salary, gold])
        XCTAssertEqual(rows.count, 3, "the two parts of the payment are one row")
        XCTAssertEqual(rows[0].parts.count, 2)
        XCTAssertTrue(rows[0].tx === p.debt, "the row opens on its biggest part")
        XCTAssertEqual(CardPaymentLegs.total(rows[0].parts, in: "IDR"), -4_699_000, accuracy: 0.5)
        XCTAssertFalse(rows[1].isJoined)
        XCTAssertTrue(rows[1].tx === salary)
        XCTAssertTrue(rows[2].tx === gold)
    }

    func testAnOrdinaryRowStandsAlone() throws {
        let bri = card("BRI", credit: false)
        let kopi = row("tomorro kopi latte", -30_000, at: paidAt, on: bri, category: .food)
        try context.save()
        XCTAssertEqual(CardPaymentLegs.all(of: kopi, in: context).count, 1)
        XCTAssertFalse(CardPaymentLegs.joined([kopi])[0].isJoined)
    }

    // MARK: The whole payment, from any part

    func testEveryPartFindsTheWholePayment() throws {
        let bri = card("BRI", credit: false), cc = card("Tokopedia CC", credit: true)
        let p = pay(debt: 4_250_000, moved: 449_000, from: bri, to: cc, at: paidAt)
        try context.save()
        let all: Set<UUID> = [p.debt.id, p.moved.id, p.onCard.id]
        XCTAssertEqual(ids(CardPaymentLegs.all(of: p.debt, in: context)), all)
        XCTAssertEqual(ids(CardPaymentLegs.all(of: p.moved, in: context)), all)
        XCTAssertEqual(ids(CardPaymentLegs.all(of: p.onCard, in: context)), all, "from the card's side too")
    }

    /// Two payments a minute apart: each keeps to its own rows.
    func testTwoPaymentsCloseTogetherStayApart() throws {
        let bri = card("BRI", credit: false), cc = card("Tokopedia CC", credit: true)
        let first = pay(debt: 1_000_000, moved: 250_000, from: bri, to: cc, at: paidAt)
        let second = pay(debt: 500_000, moved: 100_000, from: bri, to: cc, at: paidAt.addingTimeInterval(60))
        try context.save()
        XCTAssertEqual(ids(CardPaymentLegs.all(of: first.onCard, in: context)),
                       [first.debt.id, first.moved.id, first.onCard.id])
        XCTAssertEqual(ids(CardPaymentLegs.all(of: second.moved, in: context)),
                       [second.debt.id, second.moved.id, second.onCard.id])
    }

    /// A payment written before payments were split: one row on each side,
    /// the card's a few seconds later.
    func testAnOlderOneRowPaymentFindsItsCardSide() throws {
        let bri = card("BRI", credit: false), cc = card("Tokopedia CC", credit: true)
        let out = row("Tokopedia CC bill payment", -1_500_000, at: paidAt, on: bri,
                      notes: CardPaymentLegs.note, subtype: .transfer)
        let onCard = row("Payment received — Tokopedia CC", 1_500_000, at: paidAt.addingTimeInterval(3), on: cc,
                         notes: CardPaymentLegs.note, subtype: .transfer)
        try context.save()
        XCTAssertEqual(ids(CardPaymentLegs.all(of: out, in: context)), [out.id, onCard.id])
        XCTAssertFalse(CardPaymentLegs.joined([out])[0].isJoined, "one row on the list, as it always was")
    }

    // MARK: Deleting

    func testDeletingOnePartDeletesTheWholePayment() throws {
        let bri = card("BRI", credit: false), cc = card("Tokopedia CC", credit: true)
        cc.openingOwed = 4_449_000
        row("interim", 8_500_000, at: paidAt.addingTimeInterval(-7 * 60), on: bri, category: .salary)
        let p = pay(debt: 4_250_000, moved: 449_000, from: bri, to: cc, at: paidAt)
        try context.save()
        XCTAssertEqual(bri.computedBalance(), 8_500_000 - 4_699_000, accuracy: 0.5)
        XCTAssertEqual(cc.bill([]).total, 0, accuracy: 0.5)

        deleteTransactionWithGoalRollback(p.moved, context: context)
        try context.save()

        let left = try context.fetch(FetchDescriptor<TxRecord>())
        XCTAssertEqual(left.count, 1, "the salary stays; all three rows of the payment go")
        XCTAssertEqual(bri.computedBalance(), 8_500_000, accuracy: 0.5, "the money is back on BRI")
        XCTAssertEqual(cc.bill([]).total, 4_449_000, accuracy: 0.5, "and the card owes what it did")
    }

    // MARK: Words

    func testTheWordsAreInBothLanguages() {
        for language in [LanguageManager.Language.english, .indonesian] {
            LanguageManager.shared.withLanguage(language) {
                for key in ["tx.card_payment", "tx.part_debt", "tx.part_moved", "tx.parts_note",
                            "tx.delete_payment_prompt", "tx.delete_payment_note", "tx.delete_payment"] {
                    XCTAssertNotEqual(loc(key), key, "\(key) in \(language)")
                }
                let note = String(format: loc("tx.parts_note"), "Savings & debt")
                XCTAssertTrue(note.contains("Savings & debt"), note)
            }
        }
    }
}
