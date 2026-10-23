import XCTest
import SwiftData
@testable import DiPo

/// "Log an expense" and "Money left" from Siri and Shortcuts: the parts that
/// decide what is written and what is said, checked without Siri.
@MainActor
final class DiPoIntentsTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }
    private var savedMain: String?
    private var savedBills: [String] = []

    private func money(_ v: Double) -> String { CurrencyManager.shared.formatted(v, currency: "IDR") }

    override func setUpWithError() throws {
        let schema = Schema(versionedSchema: DiPoSchemaCurrent.self)
        container = try ModelContainer(for: schema,
                                       configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        savedMain = MainCard.id
        savedBills = SmartBudgetManager.shared.billCardIDs
        MainCard.id = nil
        SmartBudgetManager.shared.billCardIDs = []
    }

    override func tearDown() {
        MainCard.id = savedMain
        SmartBudgetManager.shared.billCardIDs = savedBills
        super.tearDown()
    }

    private func card(_ holder: String, _ number: String = "5221845086220969", issuer: String = "",
                      balance: Double = 0, credit: Bool = false) -> BankCard {
        let c = BankCard(holderName: holder, cardNumber: number, balance: balance, expireDate: "11/29",
                         gradientStart: "#000000", gradientEnd: "#111111", sortOrder: 0, currency: "IDR")
        c.issuerID = issuer
        c.isCreditCard = credit
        context.insert(c)
        return c
    }

    private func day(_ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: m, day: d, hour: h))!
    }

    @discardableResult
    private func row(_ name: String, _ amount: Double, _ date: Date, _ cat: TxCategory = .food,
                     subtype: TxSubtype = .normal, on c: BankCard? = nil) -> TxRecord {
        let t = TxRecord(name: name, date: date, amount: amount,
                         type: amount < 0 ? "tx.type.purchase" : "tx.type.income", icon: "X",
                         iconBgHex: cat.iconBg, category: cat, currency: "IDR", notes: "", subtype: subtype)
        context.insert(t)
        c?.transactions.append(t)
        return t
    }

    // MARK: What Siri calls a card

    func testSiriNamesACardByWhatTellsItApartNotItsHolder() {
        // Fahmi's cards: no bank chosen, the bank written into the name.
        let bri = card("Fahmi Aquinas BRI", "5221845086220969")
        let bca = card("Fahmi Aquinas BCA", "4111111111119331")
        let mandiri = card("Fahmi Aquinas Mandiri", "4111111111113661")
        let all = [bri, bca, mandiri]
        XCTAssertEqual(all.map { DiPoIntentSupport.spokenName($0, among: all) },
                       ["BRI 0969", "BCA 9331", "Mandiri 3661"])
        let chosen = card("Fahmi Aquinas", issuer: "bri")
        XCTAssertEqual(DiPoIntentSupport.spokenName(chosen, among: [chosen]), "BRI 0969")
        let wallet = BankCard(holderName: "Fahmi", cardNumber: "GoPay", balance: 0, expireDate: "Digital",
                              gradientStart: "#00AED6", gradientEnd: "#006E8A", sortOrder: 0, currency: "IDR",
                              isDigitalWallet: true, walletProvider: "GoPay")
        context.insert(wallet)
        XCTAssertEqual(DiPoIntentSupport.spokenName(wallet, among: [wallet]), "GoPay")
        let tabungan = card("Tabungan", "5221845086224821")
        XCTAssertEqual(DiPoIntentSupport.spokenName(tabungan, among: [tabungan]), "Tabungan 4821")
    }

    // MARK: Which card

    func testTheOnlyEligibleCardStandsInForAMainCardButNothingIsStored() {
        let bri = card("BRI", issuer: "bri")
        let cc = card("Kartu Kredit", "4111111111111111", credit: true)
        XCTAssertTrue(DiPoIntentSupport.mainCard(in: [bri, cc]) === bri)
        XCTAssertNil(MainCard.id, "Siri reads the choice; it never makes it")
    }

    func testSeveralCardsAndNoMainCardMeansAskingForOne() {
        let a = card("A"), b = card("B")
        XCTAssertNil(DiPoIntentSupport.mainCard(in: [a, b]))
        MainCard.set(b)
        XCTAssertTrue(DiPoIntentSupport.mainCard(in: [a, b]) === b)
        XCTAssertNil(DiPoIntentSupport.mainCard(in: [card("Kredit", credit: true)]),
                     "a credit card is never the main card")
        LanguageManager.shared.withLanguage(.english) {
            XCTAssertEqual(DiPoIntentSupport.missingCardText([]), "Add a card in DiPo first.")
            XCTAssertEqual(DiPoIntentSupport.missingCardText([a, b]), "Choose your main card in DiPo first.")
        }
    }

    // MARK: What gets written

    func testAnAmountSiriMisheardIsNotRecorded() {
        XCTAssertTrue(DiPoIntentSupport.isRecordable(25_000))
        let misheard: [Double] = [0, -25_000, .nan, .infinity, 1_000_000_000_000]
        for bad in misheard {
            XCTAssertFalse(DiPoIntentSupport.isRecordable(bad), "\(bad)")
        }
    }

    func testTheNameIsTidiedAndNeverEmpty() {
        XCTAssertEqual(DiPoIntentSupport.entryName("  kopi \n susu  "), "kopi susu")
        LanguageManager.shared.withLanguage(.english) {
            XCTAssertEqual(DiPoIntentSupport.entryName("   "), "Expense")
        }
        LanguageManager.shared.withLanguage(.indonesian) {
            XCTAssertEqual(DiPoIntentSupport.entryName(""), "Pengeluaran")
        }
        XCTAssertEqual(DiPoIntentSupport.entryName(String(repeating: "a", count: 90)).count, 60)
    }

    func testTheRowIsTheOneTheAddFormWouldWrite() {
        let tx = DiPoIntentSupport.expense(amount: 25_000, name: "Kopi", category: .food, currency: "IDR")
        XCTAssertEqual(tx.amount, -25_000)
        XCTAssertEqual(tx.type, "tx.type.purchase")
        XCTAssertEqual(tx.icon, "KO")
        XCTAssertEqual(tx.iconBgHex, TxCategory.food.iconBg)
        XCTAssertEqual(tx.category, .food)
        XCTAssertEqual(tx.currency, "IDR")
        XCTAssertEqual(tx.notes, "tx.note.from_siri")
        XCTAssertTrue(tx.hasSystemNote, "a marker DiPo wrote, shown translated and never edited")
    }

    func testTheCategoryComesFromHistoryThenKeywordsAndStaysEveryday() {
        XCTAssertEqual(DiPoIntentSupport.suggestedCategory(for: "Bensin motor", history: []), .transport)
        XCTAssertEqual(DiPoIntentSupport.suggestedCategory(for: "Pak Budi", history: []), .other)
        let fed = (1...3).map { row("Pak Budi", -50_000, day(10, $0), .food) }
        XCTAssertEqual(DiPoIntentSupport.suggestedCategory(for: "Pak Budi", history: fed), .food)
        // Learned as a debt payment, which needs a debt to pay; Siri files it
        // as an everyday expense instead.
        let owed = (1...3).map { row("Pak Budi", -500_000, day(9, $0), .debtPayment) }
        XCTAssertEqual(DiPoIntentSupport.suggestedCategory(for: "Pak Budi", history: owed), .other)
    }

    func testTheCategoriesOnOfferAreEverydaySpendingOnly() {
        XCTAssertEqual(ExpenseCategory.allCases.count, ExpenseCategory.categories.count, "one category each")
        for c in ExpenseCategory.allCases {
            XCTAssertFalse(c.category.isIncomeCategory, "\(c)")
            XCTAssertNotEqual(c.category, .debtPayment)
            XCTAssertNotNil(ExpenseCategory.caseDisplayRepresentations[c], "\(c)")
        }
    }

    // MARK: What is kept quiet

    func testHiddenBalancesAreNotReadOut() throws {
        let suite = "DiPoIntentsTests.hidden"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let main = card("BRI", issuer: "bri"), other = card("BCA", issuer: "bca")
        XCTAssertFalse(DiPoIntentSupport.balancesHidden(main: main, cards: [main, other], defaults: defaults))
        defaults.set(true, forKey: HomePrefs.hideBalancesKey)
        XCTAssertTrue(DiPoIntentSupport.balancesHidden(main: main, cards: [main, other], defaults: defaults))
        // With one account Home has no "hide all" row, so the switch does
        // nothing there either; the card's own eye does.
        XCTAssertFalse(DiPoIntentSupport.balancesHidden(main: main, cards: [main], defaults: defaults))
        main.isHidden = true
        XCTAssertTrue(DiPoIntentSupport.balancesHidden(main: main, cards: [main], defaults: defaults))
    }

    // MARK: What is said

    private func summary(start: Date? = nil, income: Double, living: Double,
                         days: Int? = nil) -> MoneyLeftSummary {
        MoneyLeftSummary(cardName: "BRI 0969", balance: 4_200_000, currency: "IDR", periodStart: start,
                         income: income, living: living, daysToPayday: days)
    }

    func testMoneyLeftSaysBalanceSpendingWhatIsLeftAndPayday() {
        let start = day(10, 23, 0)
        LanguageManager.shared.withLanguage(.english) {
            let d = DateFormatterCache.template("dMMM").string(from: start)
            XCTAssertEqual(summary(start: start, income: 10_000_000, living: 2_150_000, days: 32).text,
                           "BRI 0969 has \(money(4_200_000)). Since payday on \(d): \(money(2_150_000)) on spending"
                           + " and bills, \(money(7_850_000)) of your income left. Payday is in 32 days.")
        }
        LanguageManager.shared.withLanguage(.indonesian) {
            let d = DateFormatterCache.template("dMMM").string(from: start)
            XCTAssertEqual(summary(start: start, income: 10_000_000, living: 2_150_000, days: 32).text,
                           "Saldo BRI 0969: \(money(4_200_000)). Sejak gajian \(d): belanja & tagihan"
                           + " \(money(2_150_000)), sisa pemasukan \(money(7_850_000)). Gajian 32 hari lagi.")
        }
    }

    func testSpendingPastIncomeIsSaidAsHowFarPastNotAsAMinus() {
        LanguageManager.shared.withLanguage(.english) {
            XCTAssertEqual(summary(income: 2_000_000, living: 2_350_000).text,
                           "BRI 0969 has \(money(4_200_000)). This month: \(money(2_350_000)) on spending"
                           + " and bills, \(money(350_000)) more than your income.")
        }
    }

    func testWithNoIncomeInThePeriodNothingIsLeftOfIt() {
        LanguageManager.shared.withLanguage(.english) {
            XCTAssertEqual(summary(income: 0, living: 150_000, days: 1).text,
                           "BRI 0969 has \(money(4_200_000)). This month: \(money(150_000)) on spending"
                           + " and bills. Payday is tomorrow.")
        }
    }

    /// Home's rules: real income only, a refund takes back its expense, a
    /// card bill and a transfer are not spending, last month is not this one.
    func testMoneyLeftReadsTheFiguresHomeShows() {
        let bri = card("Fahmi Aquinas", issuer: "bri", balance: 1_000_000)
        row("Gaji", 10_000_000, day(10, 1), .salary, on: bri)
        row("Makan", -150_000, day(10, 20), .food, on: bri)
        row("Tokopedia CC bill payment", -1_500_000, day(10, 21), .debtPayment, on: bri)
        row("Refund baju", 20_000, day(10, 22), .shopping, subtype: .refund, on: bri)
        row("Transfer ke BCA", -2_000_000, day(10, 22), .other, subtype: .transfer, on: bri)
        row("Kopi", -50_000, day(9, 28), .food, on: bri)

        let s = MoneyLeftSummary.make(main: bri, cards: [bri], schedules: [], now: day(10, 23))
        XCTAssertEqual(s.cardName, "BRI 0969")
        XCTAssertNil(s.periodStart, "no salary schedule: the calendar month, as on Home")
        XCTAssertNil(s.daysToPayday)
        XCTAssertEqual(s.income, 10_000_000, accuracy: 0.5)
        XCTAssertEqual(s.living, 130_000, accuracy: 0.5)
        XCTAssertEqual(s.balance, 7_320_000, accuracy: 0.5)
    }

    // MARK: Both languages

    func testEverySiriLineIsInBothLanguages() {
        let keys = ["tx.note.from_siri", "appintent.no_card", "appintent.no_main", "appintent.log.zero",
                    "appintent.log.default_name", "appintent.log.confirm", "appintent.log.saved",
                    "appintent.money.locked", "appintent.money.hidden", "appintent.money.balance",
                    "appintent.money.lead_payday", "appintent.money.lead_month", "appintent.money.spent",
                    "appintent.money.left", "appintent.money.over", "appintent.money.payday_in",
                    "appintent.money.payday_tomorrow", "appintent.money.payday_today"]
        for language in [LanguageManager.Language.english, .indonesian] {
            LanguageManager.shared.withLanguage(language) {
                for key in keys { XCTAssertNotEqual(loc(key), key, "\(key) missing in \(language)") }
            }
        }
    }
}
