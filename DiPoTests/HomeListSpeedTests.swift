import XCTest
@testable import DiPo

/// Home's transaction list was made cheaper to draw. These pin that it shows
/// exactly what it showed before: the same amounts, character for character,
/// and the same rows in the 3- and 7-day windows.
@MainActor
final class HomeListSpeedTests: XCTestCase {

    // MARK: - Amounts

    /// `formatted` as it was: a new NumberFormatter on every call.
    private func formattedBefore(_ amount: Double, currency: String) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.groupingSize = 3
        let cur = currency.uppercased()
        let dotForGrouping: Set<String> = ["IDR","EUR","BRL","VND","DKK","ISK","NOK","SEK","TRY"]
        if dotForGrouping.contains(cur) {
            f.groupingSeparator = "."
            f.decimalSeparator = ","
        } else {
            f.groupingSeparator = ","
            f.decimalSeparator = "."
        }
        let sym = CurrencyManager.symbol(for: currency)
        if CurrencyManager.wholeUnitCurrencies.contains(cur) {
            f.maximumFractionDigits = 0
            f.minimumFractionDigits = 0
            return "\(sym) \(f.string(from: NSNumber(value: amount)) ?? "0")"
        } else {
            f.minimumFractionDigits = 2
            f.maximumFractionDigits = 2
            return "\(sym)\(f.string(from: NSNumber(value: amount)) ?? "0.00")"
        }
    }

    func testAmountsReadAsBefore() {
        let codes = CurrencyManager.supportedCurrencies.map(\.code) + ["idr", "eur", "XYZ", ""]
        let amounts: [Double] = [0, 1, -1, 9, 999, 1_000, -1_000, 25_000, -25_000, 1_234_567.891,
                                 -987_654_321.5, 0.005, 0.015, -0.004, 12.5, 99.999, 1e12, -1e15]
        for code in codes {
            for amount in amounts {
                XCTAssertEqual(CurrencyManager.shared.formatted(amount, currency: code),
                               formattedBefore(amount, currency: code), "\(amount) \(code)")
            }
        }
        // The two everyday shapes, spelled out.
        XCTAssertEqual(CurrencyManager.shared.formatted(25_000, currency: "IDR"), "Rp 25.000")
        XCTAssertEqual(CurrencyManager.shared.formatted(1_234.5, currency: "USD"), "$1,234.50")
    }

    /// Mixing currencies doesn't leak one's settings into the next: the
    /// formatters are shared, so each must stay exactly as it was set up.
    func testCurrenciesDontBleedIntoEachOther() {
        for _ in 0..<3 {
            XCTAssertEqual(CurrencyManager.shared.formatted(1_500_000, currency: "IDR"), "Rp 1.500.000")
            XCTAssertEqual(CurrencyManager.shared.formatted(1_500_000, currency: "USD"), "$1,500,000.00")
            XCTAssertEqual(CurrencyManager.shared.formatted(1_500_000, currency: "EUR"),
                           formattedBefore(1_500_000, currency: "EUR"))
            XCTAssertEqual(CurrencyManager.shared.formatted(1_500, currency: "JPY"),
                           formattedBefore(1_500, currency: "JPY"))
        }
    }

    // MARK: - The 3- and 7-day windows

    /// The list's choice of rows as it was: the whole history sorted first,
    /// then filtered.
    private func windowBefore(_ txs: [TxRecord], kind: TransactionSection.Kind, category: TxCategory?,
                              showAll: Bool, now: Date, cal: Calendar) -> TransactionSection.Window {
        let today = cal.startOfDay(for: now)
        let sorted = txs.filter(kind.matches).sorted { $0.date > $1.date }
        var out = TransactionSection.Window()
        if let filter = category {
            out.rows = sorted.filter {
                $0.category == filter && cal.isDate($0.date, equalTo: now, toGranularity: .month)
            }
        } else {
            let weekCutoff = cal.date(byAdding: .day, value: -6, to: today) ?? .distantPast
            let dayCutoff = cal.date(byAdding: .day, value: -2, to: today) ?? .distantPast
            let inWeek = sorted.filter { $0.date >= weekCutoff }
            let inDays = inWeek.filter { $0.date >= dayCutoff }
            out.hasMoreInWeek = inWeek.count > inDays.count
            out.rows = showAll ? inWeek : inDays
            out.hasOlderOutsideWindow = sorted.count > out.rows.count
        }
        return out
    }

    /// A small fixed-seed generator, so a failure can be run again as it was.
    private struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private func tx(_ date: Date, _ amount: Double, _ category: TxCategory = .food,
                    _ subtype: TxSubtype = .normal) -> TxRecord {
        TxRecord(name: "t", date: date, amount: amount, type: "tx.type.purchase", icon: "c",
                 iconBgHex: category.iconBg, category: category, currency: "IDR", subtype: subtype)
    }

    /// Six weeks of a mixed ledger, in no order, two hours into the future
    /// (a row dated later today) to forty days back.
    private func history(seed: UInt64, now: Date) -> [TxRecord] {
        var rng = SplitMix(state: seed)
        let categories: [TxCategory] = [.food, .food, .transport, .shopping, .bills, .salary, .other]
        let subtypes: [TxSubtype] = [.normal, .normal, .normal, .refund, .transfer]
        var out: [TxRecord] = []
        // Distinct times, so the newest-first order is one order.
        for i in 0..<420 {
            let date = now.addingTimeInterval(7_200 - Double(i) * 8_237)
            let amount = (Bool.random(using: &rng) ? -1 : 1) * Double(Int.random(in: 1...500, using: &rng)) * 1_000
            out.append(tx(date, amount, categories.randomElement(using: &rng)!,
                          subtypes.randomElement(using: &rng)!))
        }
        out.shuffle(using: &rng)
        return out
    }

    func testWindowsShowWhatTheyShowedBefore() {
        let cal = Calendar.current
        let now = Date()
        for seed: UInt64 in [1, 7, 42] {
            let txs = history(seed: seed, now: now)
            for kind in TransactionSection.Kind.allCases {
                for category: TxCategory? in [nil, .food, .salary, .health] {
                    for showAll in [false, true] {
                        let label = "seed \(seed) \(kind) \(String(describing: category)) showAll \(showAll)"
                        let now_ = TransactionSection.window(txs, kind: kind, category: category,
                                                             showAll: showAll, now: now, calendar: cal)
                        let then = windowBefore(txs, kind: kind, category: category,
                                                showAll: showAll, now: now, cal: cal)
                        XCTAssertEqual(now_.rows.map(\.id), then.rows.map(\.id), label)
                        XCTAssertEqual(now_.hasMoreInWeek, then.hasMoreInWeek, label)
                        XCTAssertEqual(now_.hasOlderOutsideWindow, then.hasOlderOutsideWindow, label)
                    }
                }
            }
        }
    }

    /// The edges of each window: today and the two days before it for 3
    /// days, today and the six before it for 7, newest first.
    func testWhereEachWindowEnds() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Jakarta")!
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 18))!
        let today = cal.startOfDay(for: now)
        let day = { (back: Int, h: Int, m: Int) in
            cal.date(byAdding: DateComponents(day: -back, hour: h, minute: m), to: today)!
        }
        let rows = [
            tx(day(0, 9, 0), -10_000),     // today
            tx(day(2, 0, 0), -20_000),     // first moment of the 3-day window
            tx(day(3, 23, 59), -30_000),   // last moment outside it
            tx(day(6, 0, 0), -40_000),     // first moment of the 7-day window
            tx(day(7, 23, 59), -50_000),   // last moment outside it
        ]
        let three = TransactionSection.window(rows.shuffled(), kind: .all, category: nil, showAll: false,
                                              now: now, calendar: cal)
        XCTAssertEqual(three.rows.map(\.amount), [-10_000, -20_000])
        XCTAssertTrue(three.hasMoreInWeek)
        XCTAssertTrue(three.hasOlderOutsideWindow)

        let seven = TransactionSection.window(rows.shuffled(), kind: .all, category: nil, showAll: true,
                                              now: now, calendar: cal)
        XCTAssertEqual(seven.rows.map(\.amount), [-10_000, -20_000, -30_000, -40_000])
        XCTAssertTrue(seven.hasMoreInWeek)
        XCTAssertTrue(seven.hasOlderOutsideWindow)

        // Nothing older than the week and nothing in the days it adds: the
        // 7-day choice isn't offered, and nothing is said to be left out.
        let recent = TransactionSection.window(Array(rows.prefix(2)), kind: .all, category: nil,
                                               showAll: false, now: now, calendar: cal)
        XCTAssertFalse(recent.hasMoreInWeek)
        XCTAssertFalse(recent.hasOlderOutsideWindow)
    }

    /// Out / In / Transfer narrow the window, and what they leave out counts
    /// only rows of the same kind.
    func testKindNarrowsTheWindow() {
        let now = Date()
        let rows = [
            tx(now.addingTimeInterval(-60), -15_000),
            tx(now.addingTimeInterval(-120), 4_000_000, .salary),
            tx(now.addingTimeInterval(-180), -500_000, .other, .transfer),
            tx(now.addingTimeInterval(-40 * 86_400), -25_000),
        ]
        let incoming = TransactionSection.window(rows, kind: .incoming, category: nil, showAll: false, now: now)
        XCTAssertEqual(incoming.rows.map(\.amount), [4_000_000])
        XCTAssertFalse(incoming.hasOlderOutsideWindow)

        let outgoing = TransactionSection.window(rows, kind: .outgoing, category: nil, showAll: false, now: now)
        XCTAssertEqual(outgoing.rows.map(\.amount), [-15_000])
        XCTAssertTrue(outgoing.hasOlderOutsideWindow)

        let transfers = TransactionSection.window(rows, kind: .transfer, category: nil, showAll: true, now: now)
        XCTAssertEqual(transfers.rows.map(\.amount), [-500_000])
    }
}
