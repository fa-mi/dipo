import XCTest
import SwiftData
@testable import DiPo

/// The period's cash book: start + income + other money in − spent − other
/// money out ± own moves = end. Pinned on the real case that prompted it.
@MainActor
final class PeriodCashBookTests: XCTestCase {

    private var container: ModelContainer!

    override func setUpWithError() throws {
        let schema = Schema(versionedSchema: DiPoSchemaCurrent.self)
        container = try ModelContainer(for: schema,
                                       configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    }

    private func tx(_ name: String, _ amount: Double, _ category: TxCategory = .other,
                    subtype: TxSubtype = .normal, icon: String = "X", notes: String = "") -> TxRecord {
        let t = TxRecord(name: name, date: .now, amount: amount, type: "tx.type.purchase", icon: icon,
                         iconBgHex: "#000000", category: category, currency: "IDR", notes: notes, subtype: subtype)
        container.mainContext.insert(t)
        return t
    }

    /// Fahmi's BRI card, 25 Sep – 8 Oct 2026 at 11.09: the salary spent and
    /// Rp 273.500 more, Mom repaying Rp 5 jt, three moves to his own wallet
    /// and banks. Statistics said "Left to spend Rp 0" beside Rp 4.001.015.
    private func fahmisPeriod() -> [TxRecord] {
        [
            tx("Main Salary - Salary", 10_000_000, .salary),
            // Before the spending that passed the salary, as on 4 Oct: rows
            // are stamped in the order they are made, and the walk reads dates.
            tx("Repaid by Mom", 5_000_000, subtype: .transfer, notes: "tx.note.receivable_repaid"),
            tx("kos", -2_100_000, .bills),
            tx("Tokopedia CC bill payment", -2_000_000, .debtPayment, notes: "tx.note.cc_payment"),
            tx("transfer mom", -1_000_000, .commitment),
            tx("tf ke ibuk", -1_000_000, .other),
            tx("rest of the period", -4_173_500, .food),
            tx("Transfer to OVO", -50_000, subtype: .transfer, icon: "⇄"),
            tx("Transfer to •••• 9331", -400_000, subtype: .transfer, icon: "⇄"),
            tx("Transfer to •••• 3661", -200_000, subtype: .transfer, icon: "⇄"),
        ]
    }

    func testTheRealPeriodAddsUpToTheCardBalance() {
        let book = PeriodCashBook.build(fahmisPeriod(), start: -75_485, convert: { $0.amount })
        XCTAssertEqual(book.income, 10_000_000, accuracy: 0.5)
        XCTAssertEqual(book.spent, 10_273_500, accuracy: 0.5)
        XCTAssertEqual(book.net, -273_500, accuracy: 0.5)
        XCTAssertEqual(book.otherIn, [.init(label: "Repaid by Mom", amount: 5_000_000, count: 1)])
        XCTAssertTrue(book.otherOut.isEmpty, "moves to his own accounts are not money out")
        XCTAssertEqual(book.ownMoves, -650_000, accuracy: 0.5)
        XCTAssertEqual(book.end, 4_001_015, accuracy: 0.5)
    }

    func testClosingAgainstTheBalanceRecoversTheStart() {
        let book = PeriodCashBook.build(fahmisPeriod(), end: 4_001_015, convert: { $0.amount })
        XCTAssertEqual(book.start, -75_485, accuracy: 0.5)
        XCTAssertEqual(book.end, 4_001_015, accuracy: 0.5)
    }

    /// The sentence the screen needs: the balance is up because of Mom — and
    /// by how much of her money, not all of it.
    func testOverspendCoveredByMoneyThatIsNotIncomeNamesIt() {
        let book = PeriodCashBook.build(fahmisPeriod(), start: -75_485, convert: { $0.amount })
        XCTAssertEqual(book.overspend(deficit: 273_500), .coveredBy(label: "Repaid by Mom", amount: 273_500))
        XCTAssertEqual(book.cover.coveredBy, [.init(label: "Repaid by Mom", amount: 273_500)])
    }

    func testOverspendFromSavingsAndPlain() {
        let fromSavings = PeriodCashBook.build([tx("Gaji", 1_000_000, .salary), tx("Belanja", -1_500_000, .shopping)],
                                               start: 2_000_000, convert: { $0.amount })
        XCTAssertEqual(fromSavings.overspend(deficit: 500_000), .savings)

        let broke = PeriodCashBook.build([tx("Gaji", 1_000_000, .salary), tx("Belanja", -1_500_000, .shopping)],
                                         start: 0, convert: { $0.amount })
        XCTAssertEqual(broke.overspend(deficit: 500_000), .plain, "the balance itself is below zero")

        XCTAssertNil(fromSavings.overspend(deficit: 0), "nothing to explain within income")
    }

    /// A credit card bill that is a transfer is money out, not spending, and
    /// is listed as such.
    func testCardBillTransferIsListedAsOtherMoneyOut() {
        let book = PeriodCashBook.build([tx("Gaji", 5_000_000, .salary),
                                         tx("Pay card", -1_000_000, subtype: .transfer, icon: "CC",
                                            notes: "tx.note.cc_payment")],
                                        start: 0, convert: { $0.amount })
        XCTAssertEqual(book.spent, 0, accuracy: 0.5)
        XCTAssertEqual(book.otherOut.map(\.label), [loc("stats.nonflow.cc_payment")])
        XCTAssertEqual(book.ownMoves, 0, accuracy: 0.5)
        XCTAssertEqual(book.end, 4_000_000, accuracy: 0.5)
    }

    /// 9 Oct: two Tokopedia card payments (Rp 3.882.381) pushed spending to
    /// Rp 2.311.881 over the salary, and the screens put that in red. Living
    /// costs were Rp 8.429.500 — under the salary — and are now read apart
    /// from the debt being paid down.
    func testDebtPaidIsKeptApartFromLiving() {
        let txs = fahmisPeriod() + [
            tx("Tokopedia CC bill payment", -1_882_381, .debtPayment, notes: "tx.note.cc_payment"),
            tx("more of the period", -156_000, .food),
            tx("Transfer from •••• 9331", 2_600_000, subtype: .transfer, icon: "⇄"),
        ]
        let book = PeriodCashBook.build(txs, start: -75_485, convert: { $0.amount })
        XCTAssertEqual(book.spent, 12_311_881, accuracy: 0.5)
        XCTAssertEqual(book.debtPaid, 3_882_381, accuracy: 0.5)
        XCTAssertEqual(book.living, 8_429_500, accuracy: 0.5)
        XCTAssertEqual(book.livingNet, 1_570_500, accuracy: 0.5, "living costs are under the salary")
        XCTAssertEqual(book.ownMoves, 1_950_000, accuracy: 0.5)
        XCTAssertEqual(book.end, 4_562_634, accuracy: 0.5)
    }

    func testInvestedAndRefundsAreReadByCategory() {
        let txs = [tx("Gaji", 5_000_000, .salary),
                   tx("Reksa dana", -500_000, .investment),
                   tx("Cicilan HP", -600_000, .debtPayment),
                   tx("Refund cicilan", 100_000, .debtPayment, subtype: .refund),
                   tx("Makan", -300_000, .food)]
        let book = PeriodCashBook.build(txs, start: 0, convert: { $0.amount })
        XCTAssertEqual(book.invested, 500_000, accuracy: 0.5)
        XCTAssertEqual(book.debtPaid, 500_000, accuracy: 0.5)
        XCTAssertEqual(book.living, 300_000, accuracy: 0.5)
    }

    func testMatchingTheBankMovesTheSeedByTheDifference() {
        XCTAssertEqual(MatchBalance.seed(current: 0, computed: 3_966_015, bankBalance: 4_041_500), 75_485, accuracy: 0.5)
        XCTAssertEqual(MatchBalance.seed(current: 100_000, computed: 500_000, bankBalance: 450_000), 50_000, accuracy: 0.5)
    }

    func testNewStringsInBothLanguages() {
        let keys = ["stats.pct_of_income", "stats.vs_last_period",
                    "stats.book_start", "stats.book_not_income", "stats.book_not_spending",
                    "stats.book_own_moves", "stats.metric_of_income",
                    "stats.metric_typical_day", "stats.metric_top_named",
                    "stats.safe_until", "stats.risk_until", "stats.balance_now", "stats.at_payday",
                    "stats.living_under", "stats.living_over", "stats.over_covered", "stats.over_saved",
                    "stats.debt_box", "stats.invest_box", "stats.debt_helped", "stats.book_living",
                    "stats.book_debt", "stats.book_debt_note", "stats.book_invest",
                    "stats.book_neg_start", "stats.match_cta",
                    "home.spending", "home.left_of_income", "home.over_income_label",
                    "home.debt_note", "home.invest_note", "home.balance_ok",
                    "home.over_in", "home.over_saved", "home.over_plain", "home.flow_details",
                    "match.title", "match.intro", "match.dipo_balance", "match.bank_balance",
                    "match.diff_up", "match.diff_down", "match.already", "match.forgot_hint", "match.apply",
                    "pending.source.recurring", "pending.recurring_note", "pending.recurring_gone"]
        for lang in LanguageManager.Language.allCases {
            LanguageManager.shared.withLanguage(lang) {
                for key in keys { XCTAssertNotEqual(loc(key), key, "\(lang) \(key)") }
            }
        }
    }
}
