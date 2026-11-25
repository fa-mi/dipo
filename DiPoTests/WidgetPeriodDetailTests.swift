import XCTest
import SwiftData
@testable import DiPo

/// The large Home Screen widget says what Home's period card says: what is
/// left, the period line with today above it, where the most went, and the
/// monthly expenses due before payday. The app computes it (WidgetPeriodDetail)
/// and the widget only draws it. Demo figures only.
@MainActor
final class WidgetPeriodDetailTests: XCTestCase {

    private var container: ModelContainer!

    override func setUpWithError() throws {
        let schema = Schema(versionedSchema: DiPoSchemaCurrent.self)
        container = try ModelContainer(for: schema,
                                       configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    }

    private func tx(_ amount: Double, _ category: TxCategory, subtype: TxSubtype = .normal) -> TxRecord {
        let t = TxRecord(name: category.rawValue, date: .now, amount: amount,
                         type: amount < 0 ? "tx.type.purchase" : "tx.type.income",
                         icon: "X", iconBgHex: "#000000", category: category, currency: "IDR", notes: "",
                         subtype: subtype)
        container.mainContext.insert(t)
        return t
    }

    private var rows: [TxRecord] {
        [
            tx(5_000_000, .salary),
            tx(-600_000, .food), tx(-300_000, .food), tx(100_000, .food, subtype: .refund),
            tx(-400_000, .transport),
            tx(-200_000, .shopping),
            tx(-500_000, .debtPayment),
            tx(-300_000, .investment),
            tx(-1_000_000, .other, subtype: .transfer),
        ]
    }

    private func make(_ rows: [TxRecord], income: Double = 5_000_000,
                      period: (start: Date, end: Date)? = nil, now: Date = .now,
                      days: Int? = nil, bills: [ScheduledBill] = []) -> WidgetPeriodDetail {
        WidgetPeriodDetail.make(spending: rows, income: income, period: period, now: now,
                                daysToPayday: days, bills: bills, currency: "IDR", convert: { $0.amount })
    }

    /// Living costs are the ink, debt paid and money put away the blue, as on
    /// Home: 1,4 jt and 0,8 jt of a 5 jt income. Transfers are not spending.
    func testTheLineIsHomesLine() {
        let d = make(rows)
        XCTAssertEqual(d.living, 1_400_000 / 5_000_000, accuracy: 0.0001)
        XCTAssertEqual(d.putAway, 800_000 / 5_000_000, accuracy: 0.0001)
    }

    /// The three living categories the most went to, refunds netted, largest
    /// first; debt paid and money put away are not among them.
    func testTopThreeLivingCategories() {
        let d = make(rows)
        XCTAssertEqual(d.categories.map(\.label),
                       [TxCategory.food.displayLabel, TxCategory.transport.displayLabel, TxCategory.shopping.displayLabel])
        XCTAssertEqual(d.categories[0].share, 800_000 / 1_400_000, accuracy: 0.0001)
        XCTAssertEqual(d.categories[0].hex, TxCategory.food.iconBg)
        XCTAssertEqual(d.categories[0].symbol, TxCategory.food.icon)
        XCTAssertFalse(d.categories.contains { $0.label == TxCategory.debtPayment.displayLabel })
    }

    /// No income: nothing to measure the line against, and it stays empty.
    func testNoIncomeMeansNoLine() {
        let d = make(rows, income: 0)
        XCTAssertEqual(d.living, 0)
        XCTAssertEqual(d.putAway, 0)
    }

    /// Today's place in the period, and the days to payday in Home's words.
    func testTodayAndPayday() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(30 * 86_400)
        let d = make(rows, period: (start, end), now: start.addingTimeInterval(15 * 86_400), days: 1)
        XCTAssertEqual(d.today ?? -1, 0.5, accuracy: 0.0001)
        XCTAssertEqual(d.payday, loc("home.hero.payday_tomorrow"))
        XCTAssertNil(make(rows).payday, "no salary schedule, no days to payday")
        XCTAssertNil(make(rows).today)
    }

    /// At most three bills, in the order given (earliest first).
    func testAtMostThreeBills() {
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let bills = (0..<4).map { i in
            ScheduledBill(id: "b\(i)", planID: UUID(), label: "Tagihan \(i)", amount: 100_000,
                          planAmount: 100_000, planCurrency: "IDR",
                          due: day.addingTimeInterval(Double(i) * 86_400), category: .bills)
        }
        let d = make(rows, bills: bills)
        XCTAssertEqual(d.bills.map(\.label), ["Tagihan 0", "Tagihan 1", "Tagihan 2"])
        XCTAssertFalse(d.bills[0].due.isEmpty)
    }

    /// The JSON's fields are the contract with the widget's copy of this type.
    func testTheWidgetReadsTheSameFields() throws {
        let data = try JSONEncoder().encode(make(rows, period: (Date(), Date().addingTimeInterval(86_400)), days: 3))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let fields = ["living", "putAway", "today", "payday", "categories", "bills",
                      "labelToday", "labelTop", "labelBills", "labelNoBills"]
        XCTAssertEqual(Set(json.keys), Set(fields))

        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let widget = try String(contentsOf: root.appendingPathComponent("DiPoWidget/DiPoWidget.swift"), encoding: .utf8)
        for field in fields + ["label", "amount", "share", "hex", "symbol", "due"] {
            XCTAssertTrue(widget.contains("var \(field):"), "the widget's copy has no \(field)")
        }
        XCTAssertTrue(widget.contains("static let storeKey = \"\(WidgetPeriodDetail.storeKey)\""))
        XCTAssertTrue(widget.contains(".systemLarge"), "the large size isn't offered")
    }

    /// The widget's figures count credit-card purchases, as Home's do, and a
    /// sign-out clears the large size's period too.
    func testTheWidgetCountsCardPurchasesAndClears() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let sync = try String(contentsOf: root.appendingPathComponent("RootView.swift"), encoding: .utf8)
        XCTAssertTrue(sync.contains("MainCard.budgetSpendingTransactions(in: allCards)"))
        XCTAssertFalse(sync.contains("MainCard.potTransactions(in: allCards) ?? allTxs"))
        XCTAssertTrue(sync.contains("WidgetPeriodDetail.storeKey,"), "clear() leaves the large widget's period")
    }

    func testNewStringsInBothLanguages() {
        for lang in LanguageManager.Language.allCases {
            LanguageManager.shared.withLanguage(lang) {
                for key in ["widget.large.top", "widget.large.bills", "widget.large.no_bills"] {
                    XCTAssertNotEqual(loc(key), key, "\(lang) \(key)")
                }
            }
        }
    }
}
