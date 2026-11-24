import XCTest
import SwiftData
@testable import DiPo

/// Credit-card purchases count as the period's spending (Home's period card,
/// Statistics, the Siri summary) while the balance stays the pot's cash: a
/// purchase on a card is on its bill, and paying that bill later is a
/// transfer, so nothing is counted twice.
///
/// Before, a credit card outside the pot meant its purchases were counted
/// nowhere, and the period's "Left" read higher than the money really left.
@MainActor
final class CardSpendingTests: XCTestCase {

    private var container: ModelContainer!

    override func setUpWithError() throws {
        let schema = Schema(versionedSchema: DiPoSchemaCurrent.self)
        container = try ModelContainer(for: schema,
                                       configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    }

    private func tx(_ name: String, _ amount: Double, _ category: TxCategory = .other,
                    subtype: TxSubtype = .normal, notes: String = "") -> TxRecord {
        let t = TxRecord(name: name, date: .now, amount: amount, type: amount < 0 ? "tx.type.purchase" : "tx.type.income",
                         icon: "X", iconBgHex: "#000000", category: category, currency: "IDR", notes: notes,
                         subtype: subtype)
        container.mainContext.insert(t)
        return t
    }

    /// The pot's own rows: salary, living costs, an instalment paid as a
    /// debt payment, and the plain part of a card bill paid as a transfer.
    private func potRows() -> [TxRecord] {
        [
            tx("Gaji", 10_000_000, .salary),
            tx("Belanja harian", -6_000_000, .food),
            tx("Cicilan kartu", -2_000_000, .debtPayment),
            tx("Card bill payment", -500_000, subtype: .transfer, notes: "tx.note.cc_payment"),
        ]
    }

    /// On the card: two purchases and a refund.
    private func cardRows() -> [TxRecord] {
        [
            tx("Sepatu", -1_500_000, .shopping),
            tx("Gym", -500_000, .health),
            tx("Refund sepatu", 100_000, .shopping, subtype: .refund),
        ]
    }

    func testCardPurchasesCountButLeaveTheBalanceAlone() {
        let book = PeriodCashBook.build(potRows(), start: 300_000, convert: { $0.amount },
                                        cardSpending: cardRows())
        XCTAssertEqual(book.onCard, 1_900_000, accuracy: 0.5, "two purchases less the refund")
        XCTAssertEqual(book.spent, 6_000_000 + 2_000_000 + 1_900_000, accuracy: 0.5)
        XCTAssertEqual(book.debtPaid, 2_000_000, accuracy: 0.5)
        XCTAssertEqual(book.living, 7_900_000, accuracy: 0.5, "living costs include what went on the card")
        XCTAssertEqual(book.livingNet, 2_100_000, accuracy: 0.5)
        // The balance is the cash: 300.000 + 10 jt − 6 jt − 2 jt − 500.000.
        XCTAssertEqual(book.end, 1_800_000, accuracy: 0.5)
    }

    /// Without card rows the book is what it always was.
    func testNoCardMeansNoChange() {
        let with = PeriodCashBook.build(potRows(), start: 300_000, convert: { $0.amount })
        XCTAssertEqual(with.onCard, 0)
        XCTAssertEqual(with.living, 6_000_000, accuracy: 0.5)
        XCTAssertEqual(with.end, 1_800_000, accuracy: 0.5)
    }

    /// Closed against today's balance (how Home builds it), the start comes
    /// out the same: the card's purchases don't move it.
    func testClosingAgainstTheBalanceStillFindsTheStart() {
        let book = PeriodCashBook.build(potRows(), end: 1_800_000, convert: { $0.amount },
                                        cardSpending: cardRows())
        XCTAssertEqual(book.start, 300_000, accuracy: 0.5)
        XCTAssertEqual(book.end, 1_800_000, accuracy: 0.5)
    }

    /// Living past income: only the part the balance paid for is explained
    /// by where the money came from; what went on a card is on its bill.
    func testTheBalanceOnlyAnswersForWhatItPaid() {
        let allOnCard = PeriodCashBook.build([tx("Gaji", 5_000_000, .salary), tx("Makan", -4_000_000, .food)],
                                             start: 1_000_000, convert: { $0.amount },
                                             cardSpending: [tx("Laptop", -2_000_000, .shopping)])
        XCTAssertEqual(allOnCard.livingNet, -1_000_000, accuracy: 0.5)
        XCTAssertEqual(allOnCard.cashOverspend, 0, accuracy: 0.5, "the card paid the whole gap")

        let partly = PeriodCashBook.build([tx("Gaji", 5_000_000, .salary), tx("Makan", -5_500_000, .food)],
                                          start: 1_000_000, convert: { $0.amount },
                                          cardSpending: [tx("Laptop", -1_000_000, .shopping)])
        XCTAssertEqual(partly.livingNet, -1_500_000, accuracy: 0.5)
        XCTAssertEqual(partly.cashOverspend, 500_000, accuracy: 0.5)
    }

    /// The sentence says how much went on a card and that it is on the bill,
    /// in both languages.
    func testTheCardIsSaidInWords() {
        let book = PeriodCashBook.build(potRows(), start: 300_000, convert: { $0.amount },
                                        cardSpending: cardRows())
        let money: (Double) -> String = { "Rp \(Int($0.rounded()))" }
        LanguageManager.shared.withLanguage(.indonesian) {
            let text = book.cardSentence(money: money) ?? ""
            XCTAssertTrue(text.contains("Rp 1900000"), text)
            XCTAssertTrue(text.contains("kartu kredit"), text)
            XCTAssertTrue(book.livingSentence(money: money).contains("kartu kredit"))
        }
        LanguageManager.shared.withLanguage(.english) {
            XCTAssertTrue((book.cardSentence(money: money) ?? "").contains("credit card"))
        }
        let none = PeriodCashBook.build(potRows(), start: 0, convert: { $0.amount })
        XCTAssertNil(none.cardSentence(money: money))
    }

    /// A card's purchases are counted; the payment arriving on it is not.
    func testOnlyPurchasesAndRefundsComeFromTheCard() throws {
        let ctx = container.mainContext
        let bri = BankCard(holderName: "BRI", cardNumber: "0123456789010969", balance: 0, expireDate: "11/29",
                           gradientStart: "#000000", gradientEnd: "#000000", sortOrder: 0, currency: "IDR")
        let cc = BankCard(holderName: "Kartu Kredit", cardNumber: "0123456789010001", balance: 0, expireDate: "11/29",
                          gradientStart: "#000000", gradientEnd: "#000000", sortOrder: 1, currency: "IDR")
        cc.isCreditCard = true
        ctx.insert(bri); ctx.insert(cc)
        cc.transactions.append(contentsOf: cardRows())
        cc.transactions.append(tx("Payment received — Kartu Kredit", 500_000, subtype: .transfer))
        let counted = MainCard.creditCardSpending(in: [bri, cc])
        XCTAssertEqual(counted.count, 3)
        XCTAssertFalse(counted.contains { $0.txSubtype == .transfer })
    }

    /// Home's period card, Statistics, the Siri summary and the recap all
    /// read card purchases; the cash book is built from the pot alone.
    func testEveryPeriodViewReadsCardPurchases() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func source(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        XCTAssertTrue(try source("HomeView.swift").contains("MainCard.budgetSpendingCardIDs(in: queriedCards)"))
        XCTAssertTrue(try source("HomeView.swift").contains("cardSpending: cardSpending"))
        XCTAssertTrue(try source("DiPo/StatisticsView+Figures.swift")
            .contains("scopeCashTransactions + cardSpendingTransactions"))
        XCTAssertTrue(try source("DiPo/StatisticsView+MainPage.swift").contains("cardSpending: filteredCardTx"))
        XCTAssertTrue(try source("DiPo/DiPoIntents.swift").contains("MainCard.creditCardSpending(in: cards)"))
        XCTAssertTrue(try source("DiPo/MonthlyRecap.swift").contains("MainCard.budgetSpendingTransactions(in: cards)"))
    }
}
