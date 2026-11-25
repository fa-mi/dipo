import XCTest
import SwiftData
@testable import DiPo

/// The Apple Watch shows what is left of the period and logs cash spending.
/// The iPhone computes what it shows (WatchSnapshot) and saves what it logs
/// (WatchBridge.save). Demo figures only.
@MainActor
final class WatchSnapshotTests: XCTestCase {

    private var container: ModelContainer!
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUpWithError() throws {
        let schema = Schema(versionedSchema: DiPoSchemaCurrent.self)
        container = try ModelContainer(for: schema,
                                       configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        suite = "WatchSnapshotTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func money(_ v: Double) -> String { CurrencyManager.shared.formatted(v, currency: "IDR") }

    private func detail(today: Double? = 0.8, payday: String? = "6 hari lagi gajian") -> WidgetPeriodDetail {
        WidgetPeriodDetail(living: 0.6, putAway: 0.1, today: today, payday: payday, categories: [], bills: [],
                           labelToday: "", labelTop: "", labelBills: "", labelNoBills: "")
    }

    private func card() -> BankCard {
        let c = BankCard(holderName: "Demo BRI", cardNumber: "0000000000004021", balance: 1_000_000,
                         expireDate: "11/29", gradientStart: "#000000", gradientEnd: "#000000",
                         sortOrder: 0, currency: "IDR")
        container.mainContext.insert(c)
        return c
    }

    private func tx(_ amount: Double, _ category: TxCategory, daysAgo: Double = 1) -> TxRecord {
        let t = TxRecord(name: category.rawValue, date: Date().addingTimeInterval(-daysAgo * 86_400), amount: amount,
                         type: amount < 0 ? "tx.type.purchase" : "tx.type.income",
                         icon: "X", iconBgHex: "#000000", category: category, currency: "IDR", notes: "")
        container.mainContext.insert(t)
        return t
    }

    // MARK: What the watch shows

    /// 1,5 jt left of a 5 jt income with 6 days to payday: about 250.000 a day.
    func testWhatIsLeftAndThePace() {
        let s = WatchSnapshot.make(detail: detail(), income: 5_000_000, expenses: 3_500_000, daysToPayday: 6,
                                   currency: "IDR", main: nil, cards: [], history: [])
        XCTAssertEqual(s.amount, money(1_500_000))
        XCTAssertFalse(s.over)
        XCTAssertEqual(s.labels.title, loc("watch.left"))
        XCTAssertEqual(s.perDay, String(format: loc("watch.per_day"), money(250_000)))
        XCTAssertEqual(s.living, 0.6)
        XCTAssertEqual(s.putAway, 0.1)
        XCTAssertNil(s.cardName, "no main card: the watch can't log")
    }

    /// Past income the amount is how far over, and there is no pace to give.
    func testOverIncome() {
        let s = WatchSnapshot.make(detail: detail(), income: 5_000_000, expenses: 5_500_000, daysToPayday: 6,
                                   currency: "IDR", main: nil, cards: [], history: [])
        XCTAssertTrue(s.over)
        XCTAssertEqual(s.amount, money(500_000))
        XCTAssertEqual(s.labels.title, loc("watch.over"))
        XCTAssertNil(s.perDay)
    }

    /// Without income the watch shows what was spent, as the widget does.
    func testWithoutIncomeItShowsSpending() {
        let s = WatchSnapshot.make(detail: detail(payday: nil), income: 0, expenses: 800_000, daysToPayday: nil,
                                   currency: "IDR", main: nil, cards: [], history: [])
        XCTAssertEqual(s.labels.title, loc("watch.spent"))
        XCTAssertEqual(s.amount, money(800_000))
        XCTAssertNil(s.perDay)
    }

    /// The grid offers the everyday categories used most in 90 days, topped
    /// up from the starter set; debt payments, income and old rows don't count.
    func testTheMostUsedCategories() {
        var rows = (0..<3).map { _ in tx(-20_000, .food) }
        rows += (0..<2).map { _ in tx(-15_000, .transport) }
        rows.append(tx(-50_000, .health))
        rows += (0..<5).map { _ in tx(-500_000, .debtPayment) }
        rows.append(tx(5_000_000, .salary))
        rows += (0..<10).map { _ in tx(-20_000, .bills, daysAgo: 100) }
        XCTAssertEqual(WatchSnapshot.mostUsed(in: rows), [.food, .transport, .health, .shopping])
        XCTAssertEqual(WatchSnapshot.mostUsed(in: []), WatchSnapshot.starterCategories)
    }

    // MARK: Saving what the watch logs

    private func entry(_ amount: Double, _ category: TxCategory = .food, id: String = UUID().uuidString,
                       at: Date = Date()) -> WatchEntry {
        WatchEntry(id: id, amount: amount, category: category.rawValue, at: at)
    }

    /// An entry lands on the main card as an expense from the watch, once.
    func testAnEntryIsSavedOnce() {
        let main = card()
        let e = entry(25_000)
        XCTAssertTrue(WatchBridge.save(e, in: container.mainContext, defaults: defaults))
        XCTAssertFalse(WatchBridge.save(e, in: container.mainContext, defaults: defaults), "delivered twice, saved once")
        XCTAssertEqual(main.transactions.count, 1)
        let tx = main.transactions[0]
        XCTAssertEqual(tx.amount, -25_000)
        XCTAssertEqual(tx.category, .food)
        XCTAssertEqual(tx.notes, "tx.note.from_watch")
    }

    /// Nothing out of bounds is saved; a category that isn't an everyday
    /// one becomes Other; a watch clock ahead can't post into the future.
    func testWhatIsRefusedOrTidied() {
        let main = card()
        XCTAssertFalse(WatchBridge.save(entry(0), in: container.mainContext, defaults: defaults))
        XCTAssertFalse(WatchBridge.save(entry(-5_000), in: container.mainContext, defaults: defaults))
        XCTAssertFalse(WatchBridge.save(entry(.infinity), in: container.mainContext, defaults: defaults))
        let now = Date()
        XCTAssertTrue(WatchBridge.save(entry(10_000, .salary, at: now.addingTimeInterval(3_600)),
                                       in: container.mainContext, defaults: defaults, now: now))
        XCTAssertEqual(main.transactions.count, 1)
        XCTAssertEqual(main.transactions[0].category, .other)
        XCTAssertEqual(main.transactions[0].date, now)
    }

    /// No card to save to: nothing is saved.
    func testNoCardNoSave() {
        XCTAssertFalse(WatchBridge.save(entry(25_000), in: container.mainContext, defaults: defaults))
    }

    // MARK: The contract with the watch

    /// The snapshot's fields are the ones the watch app and its
    /// complications decode, and the keys they travel under match.
    func testTheWatchReadsTheSameFields() throws {
        let main = card()
        let s = WatchSnapshot.make(detail: detail(), income: 5_000_000, expenses: 3_500_000, daysToPayday: 6,
                                   currency: "IDR", main: main, cards: [main], history: [])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as? [String: Any])
        let fields = ["amount", "over", "hidden", "living", "putAway", "today", "payday", "perDay",
                      "categories", "currency", "cardName", "labels", "updated"]
        XCTAssertEqual(Set(json.keys), Set(fields))
        let labels = try XCTUnwrap(json["labels"] as? [String: Any])
        let labelFields = ["title", "log", "forWhat", "saved", "savedTo", "pending", "noCard"]
        XCTAssertEqual(Set(labels.keys), Set(labelFields))

        let watch = try source("DiPoWatch Watch App/WatchSnapshot.swift")
        for field in fields + labelFields + ["raw", "label", "hex", "symbol"] {
            XCTAssertTrue(watch.contains("var \(field):"), "the watch app's copy has no \(field)")
        }
        XCTAssertTrue(watch.contains("static let contextKey = \"\(WatchSnapshot.contextKey)\""))
        XCTAssertTrue(watch.contains("static let userInfoKey = \"\(WatchEntry.userInfoKey)\""))
        for field in ["id", "amount", "category", "at"] {
            XCTAssertTrue(watch.contains("var \(field):"), "the watch's entry has no \(field)")
        }

        let complication = try source("DiPoWatchWidget/WatchSnapshot.swift")
        for field in ["amount", "over", "hidden", "living", "putAway", "payday", "labels", "title"] {
            XCTAssertTrue(complication.contains("var \(field):"), "the complication's copy has no \(field)")
        }
        let store = try source("DiPoWatch Watch App/WatchSnapshot.swift")
        XCTAssertTrue(store.contains("static let storeKey = \"watch.snapshot\""))
        XCTAssertTrue(complication.contains("static let storeKey = \"watch.snapshot\""))
    }

    /// Both watch bundles declare why they read UserDefaults.
    func testTheWatchBundlesHavePrivacyManifests() throws {
        for path in ["DiPoWatch Watch App/PrivacyInfo.xcprivacy", "DiPoWatchWidget/PrivacyInfo.xcprivacy"] {
            let text = try source(path)
            XCTAssertTrue(text.contains("NSPrivacyAccessedAPICategoryUserDefaults"), path)
            XCTAssertTrue(text.contains("1C8F.1"), path)
        }
    }

    /// The watch gets the figures every time the widgets do, forgets them on
    /// sign-out, and a test run never opens the connection.
    func testTheBridgeIsWiredAndOffInTests() throws {
        let sync = try source("RootView.swift")
        XCTAssertTrue(sync.contains("WatchBridge.shared.send(WatchSnapshot.make("))
        XCTAssertTrue(sync.contains("WatchBridge.shared.clear()"))
        XCTAssertTrue(try source("FinanceAppMain.swift").contains("WatchBridge.shared.start()"))
        XCTAssertTrue(try source("DiPo/WatchBridge.swift").contains("guard RunContext.isOnline, WCSession.isSupported()"))
        XCTAssertFalse(RunContext.isOnline)
    }

    func testTheWordsInBothLanguages() {
        let keys = ["watch.left", "watch.over", "watch.spent", "watch.per_day", "watch.log", "watch.for_what",
                    "watch.saved", "watch.saved_to", "watch.pending", "watch.no_card", "tx.note.from_watch"]
        for lang in LanguageManager.Language.allCases {
            LanguageManager.shared.withLanguage(lang) {
                for key in keys { XCTAssertNotEqual(loc(key), key, "\(lang) \(key)") }
                XCTAssertTrue(loc("watch.per_day").contains("%@"))
                XCTAssertTrue(loc("watch.for_what").contains("%@"))
                XCTAssertTrue(loc("watch.saved_to").contains("%@"))
            }
        }
    }
}
