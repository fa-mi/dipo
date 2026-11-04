import XCTest
import SwiftData
@testable import DiPo

/// The month that just ended, read the way Statistics reads it, and the
/// reminder that announces it on the 1st.
@MainActor
final class MonthlyRecapTests: XCTestCase {

    private var container: ModelContainer!
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Jakarta")!
        return c
    }()

    override func setUpWithError() throws {
        let schema = Schema(versionedSchema: DiPoSchemaCurrent.self)
        container = try ModelContainer(for: schema,
                                       configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    @discardableResult
    private func tx(_ amount: Double, _ category: TxCategory, on day: Date,
                    _ subtype: TxSubtype = .normal) -> TxRecord {
        let t = TxRecord(name: category.rawValue, date: day, amount: amount, type: "tx.type.purchase",
                         icon: "X", iconBgHex: "#000000", category: category, currency: "IDR",
                         subtype: subtype)
        container.mainContext.insert(t)
        return t
    }

    private let plain: (TxRecord) -> Double = { $0.amount }

    // MARK: Totals

    /// Income is real income; spending is spending & bills, refunds taken off,
    /// transfers skipped, debt paid and money saved kept apart — and only rows
    /// inside the month count.
    func testTheTotalsAreStatistics() throws {
        let october = date(2026, 10, 1, 0, 0)
        let rows = [
            tx(4_200_000, .salary, on: date(2026, 10, 1, 8)),
            tx(-100_000, .food, on: date(2026, 10, 3)),
            tx(-100_000, .food, on: date(2026, 10, 9)),
            tx(-100_000, .food, on: date(2026, 10, 30)),
            tx(-759_000, .bills, on: date(2026, 10, 5)),
            tx(-500_000, .shopping, on: date(2026, 10, 12)),
            tx(86_000, .shopping, on: date(2026, 10, 14), .refund),
            tx(-1_000_000, .other, on: date(2026, 10, 15), .transfer),
            tx(-650_000, .debtPayment, on: date(2026, 10, 25)),
            tx(-300_000, .investment, on: date(2026, 10, 26)),
        ]
        // Either side of the month.
        tx(-999, .food, on: date(2026, 11, 1, 0, 0))
        tx(-999, .food, on: date(2026, 9, 30, 23, 59))
        let all = try container.mainContext.fetch(FetchDescriptor<TxRecord>())

        let r = try XCTUnwrap(MonthlyRecap.build(all, month: october, cal: cal, convert: plain))
        XCTAssertEqual(r.month, october)
        XCTAssertEqual(r.income, 4_200_000)
        XCTAssertEqual(r.spent, 1_473_000)
        XCTAssertEqual(r.debtPaid, 650_000)
        XCTAssertEqual(r.saved, 300_000)
        XCTAssertEqual(r.left, 2_727_000)

        // The same figures Statistics shows for those rows.
        XCTAssertEqual(r.income, StatisticsView.income(rows, convert: plain))
        XCTAssertEqual(r.spent, StatisticsView.living(rows, convert: plain))

        XCTAssertEqual(r.rows.map(\.category), [.bills, .shopping, .food])
        XCTAssertEqual(r.rows.map(\.amount), [759_000, 414_000, 300_000])
        XCTAssertEqual(r.rows.map(\.count), [1, 1, 3])
        XCTAssertEqual(r.txCount, 5)
        XCTAssertEqual(r.rows.reduce(0) { $0 + $1.share }, 1, accuracy: 0.0001)
        XCTAssertEqual(r.rows[0].share, 759_000 / 1_473_000, accuracy: 0.0001)
    }

    /// A month with nothing in it has no summary, rather than one of zeros.
    func testAnEmptyMonthHasNoSummary() throws {
        tx(-1_000_000, .other, on: date(2026, 10, 15), .transfer)
        let all = try container.mainContext.fetch(FetchDescriptor<TxRecord>())
        XCTAssertNil(MonthlyRecap.build(all, month: date(2026, 10, 1), cal: cal, convert: plain))
        XCTAssertNil(MonthlyRecap.build(all, month: date(2026, 9, 1), cal: cal, convert: plain))
    }

    /// Money that came back is not a place the money went.
    func testARefundedCategoryIsNotListed() throws {
        tx(-100_000, .shopping, on: date(2026, 10, 2))
        tx(200_000, .shopping, on: date(2026, 10, 3), .refund)
        tx(-50_000, .food, on: date(2026, 10, 4))
        let all = try container.mainContext.fetch(FetchDescriptor<TxRecord>())
        let r = try XCTUnwrap(MonthlyRecap.build(all, month: date(2026, 10, 1), cal: cal, convert: plain))
        XCTAssertEqual(r.rows.map(\.category), [.food])
        XCTAssertEqual(r.rows.first?.share, 1)
    }

    /// Any day of the month opens that month's summary.
    func testAnyDayNamesItsMonth() throws {
        tx(-10_000, .food, on: date(2026, 10, 31, 23, 30))
        let all = try container.mainContext.fetch(FetchDescriptor<TxRecord>())
        let r = try XCTUnwrap(MonthlyRecap.build(all, month: date(2026, 10, 17), cal: cal, convert: plain))
        XCTAssertEqual(r.month, date(2026, 10, 1, 0, 0))
        XCTAssertEqual(r.spent, 10_000)
    }

    // MARK: Against the month before

    func testTheChangeIsInWholePercent() {
        XCTAssertEqual(MonthlyRecap.change(92, from: 100), -8)
        XCTAssertEqual(MonthlyRecap.change(112, from: 100), 12)
        XCTAssertEqual(MonthlyRecap.change(100.4, from: 100), 0)
        XCTAssertEqual(MonthlyRecap.change(0, from: 100), -100)
        // Nothing to compare with.
        XCTAssertNil(MonthlyRecap.change(100, from: 0))
    }

    // MARK: The reminder

    /// The 1st at 09:00, about the month that just ended — never about the
    /// month it goes off in. Opening the app on the 1st before 09:00 used to
    /// reschedule it with the new month's empty figures.
    func testTheReminderIsAboutTheMonthThatEnded() throws {
        let midMonth = try XCTUnwrap(MonthlyRecap.nextReminder(after: date(2026, 10, 20, 10), cal: cal))
        XCTAssertEqual(midMonth.fire, date(2026, 11, 1, 9, 0))
        XCTAssertEqual(midMonth.month, date(2026, 10, 1, 0, 0))

        let earlyOnThe1st = try XCTUnwrap(MonthlyRecap.nextReminder(after: date(2026, 11, 1, 8, 0), cal: cal))
        XCTAssertEqual(earlyOnThe1st.fire, date(2026, 11, 1, 9, 0))
        XCTAssertEqual(earlyOnThe1st.month, date(2026, 10, 1, 0, 0))

        let afterIt = try XCTUnwrap(MonthlyRecap.nextReminder(after: date(2026, 11, 1, 9, 0), cal: cal))
        XCTAssertEqual(afterIt.fire, date(2026, 12, 1, 9, 0))
        XCTAssertEqual(afterIt.month, date(2026, 11, 1, 0, 0))

        let newYear = try XCTUnwrap(MonthlyRecap.nextReminder(after: date(2026, 12, 31, 22), cal: cal))
        XCTAssertEqual(newYear.fire, date(2027, 1, 1, 9, 0))
        XCTAssertEqual(newYear.month, date(2026, 12, 1, 0, 0))
    }

    func testTheLastFinishedMonth() {
        XCTAssertEqual(MonthlyRecap.lastFinishedMonth(before: date(2026, 11, 3), cal: cal), date(2026, 10, 1, 0, 0))
        XCTAssertEqual(MonthlyRecap.lastFinishedMonth(before: date(2027, 1, 1, 0, 5), cal: cal), date(2026, 12, 1, 0, 0))
        XCTAssertEqual(MonthlyRecap.key(date(2026, 10, 1), cal: cal), "2026-10")
        XCTAssertEqual(MonthlyRecap.key(date(2027, 1, 15), cal: cal), "2027-01")
    }

    /// The push says only that the summary is ready: a figure in it would be
    /// whatever was known when the app was last opened.
    func testThePushCarriesNoFigures() {
        for lang in LanguageManager.Language.allCases {
            LanguageManager.shared.withLanguage(lang) {
                XCTAssertFalse(loc("notif.monthly.body").contains("%"), "\(lang)")
                XCTAssertEqual(loc("notif.monthly.title").components(separatedBy: "%@").count, 2, "\(lang)")
            }
        }
    }

    /// Tapping the reminder opens the summary; nothing else does.
    func testTheReminderOpensTheSummary() {
        XCTAssertTrue(AppDelegate.opensMonthlyRecap(["route": NotificationRoute.monthlyRecap.rawValue]))
        XCTAssertFalse(AppDelegate.opensMonthlyRecap(["route": NotificationRoute.smartBudget.rawValue]))
        XCTAssertFalse(AppDelegate.opensMonthlyRecap(["cardId": "x"]))
        XCTAssertFalse(AppDelegate.opensMonthlyRecap([:]))
        XCTAssertEqual(NotificationRoute.monthlyRecap.notificationName, .requestOpenMonthlyRecap)
    }

    /// A cold launch hands the tap over once.
    func testTheTapIsHandedOverOnce() {
        _ = MonthlyRecapRoute.shared.consume()
        MonthlyRecapRoute.shared.open()
        XCTAssertTrue(MonthlyRecapRoute.shared.consume())
        XCTAssertFalse(MonthlyRecapRoute.shared.consume())
    }

    // MARK: Words

    func testWords() {
        LanguageManager.shared.withLanguage(.indonesian) {
            XCTAssertEqual(String(format: loc("recap.down"), 8, "Sep"), "Turun 8% dari Sep")
            XCTAssertEqual(String(format: loc("recap.up"), 12, "Sep"), "Naik 12% dari Sep")
            XCTAssertEqual(String(format: loc("notif.monthly.title"), "Oktober"), "Ringkasan Oktober sudah siap")
            XCTAssertEqual(String(format: loc("recap.tx_count"), 21), "21 transaksi")
        }
        LanguageManager.shared.withLanguage(.english) {
            XCTAssertEqual(String(format: loc("recap.down"), 8, "Sep"), "Down 8% from Sep")
            XCTAssertEqual(String(format: loc("notif.monthly.title"), "October"), "Your October summary is ready")
        }
    }

    func testStringsInBothLanguages() {
        let keys = ["notif.monthly.title", "notif.monthly.body", "notif.monthly.item_body",
                    "notif.monthly.advice", "notif.route.recap",
                    "recap.title", "recap.headline", "recap.spent", "recap.income", "recap.up",
                    "recap.down", "recap.same", "recap.left", "recap.over", "recap.left_sub",
                    "recap.where", "recap.tx_one", "recap.tx_count", "recap.kept_both",
                    "recap.kept_debt", "recap.kept_saved", "recap.matches", "recap.empty",
                    "recap.empty_sub", "recap.prev", "recap.next"]
        for lang in LanguageManager.Language.allCases {
            LanguageManager.shared.withLanguage(lang) {
                for k in keys { XCTAssertNotEqual(loc(k), k, "\(k) in \(lang)") }
            }
        }
    }
}
