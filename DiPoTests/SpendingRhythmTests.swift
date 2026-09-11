import XCTest
@testable import DiPo

// Tests for the engine that decides which spending is day-to-day.
//
// Every case here is a bug that actually shipped or nearly did. The rule was
// rewritten three times before it worked, and each rewrite was wrong in a way
// the previous one was not — so these are less a safety net than a record of
// what "correct" turned out to mean.
final class SpendingRhythmTests: XCTestCase {

    // MARK: Fixtures

    private func tx(_ amount: Double, _ category: TxCategory,
                    daysAgo: Int, name: String = "x") -> TxRecord {
        TxRecord(name: name,
                 date: Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!,
                 amount: -abs(amount), type: "expense", icon: "", iconBgHex: "",
                 category: category, currency: "IDR")
    }

    /// A history spread evenly across `days`, so cadence is exactly
    /// days / count and the test states the frequency it means to test.
    private func spread(_ count: Int, _ amount: Double,
                        _ category: TxCategory, over days: Int) -> [TxRecord] {
        (0..<count).map { i in
            tx(amount, category, daysAgo: days - 1 - (i * days / max(count, 1)))
        }
    }

    private func rhythm(_ history: [TxRecord]) -> SpendingRhythm {
        SpendingRhythm(history: history) { $0.amount }
    }

    // MARK: Not enough history

    func testStaysSilentBelowMinimumTransactions() {
        let r = rhythm(spread(5, 20_000, .food, over: 30))
        XCTAssertFalse(r.isReady)
        // Silence means "counts as day-to-day", never "irregular": guessing a
        // stranger's rhythm from five purchases is worse than not guessing.
        XCTAssertEqual(r.autoVerdict(for: tx(5_000_000, .food, daysAgo: 1), amount: 5_000_000),
                       .dayToDay)
    }

    func testStaysSilentBelowMinimumDays() {
        let r = rhythm(spread(40, 20_000, .food, over: 5))
        XCTAssertFalse(r.isReady)
    }

    // MARK: Cadence decides the category

    func testFrequentCategoryIsAlwaysDayToDay() {
        // 200 purchases over 60 days — food, several times a day.
        var history = spread(200, 25_000, .food, over: 60)
        let dinner = tx(310_000, .food, daysAgo: 2)
        history.append(dinner)
        let r = rhythm(history)
        XCTAssertTrue(r.isReady)
        // An expensive dinner in a habit category is not an anomaly. An earlier
        // rule flagged thirteen of these on real data.
        XCTAssertEqual(r.autoVerdict(for: dinner, amount: 310_000), .dayToDay)
    }

    func testRareCategoryIsEpisodicWholesale() {
        var history = spread(200, 25_000, .food, over: 60)
        let ticket = tx(800_000, .travel, daysAgo: 3)
        history += spread(4, 775_000, .travel, over: 60) + [ticket]
        let r = rhythm(history)
        // Travel touched every ~12 days. A train fare is not a commute — and
        // the earlier amount-based rule MISSED this exact case, because
        // Travel's typical amount is already large.
        XCTAssertEqual(r.autoVerdict(for: ticket, amount: 800_000), .episodicCategory)
    }

    func testMiddleCadenceUsesOutlierTest() {
        var history = spread(200, 25_000, .food, over: 60)
        // "Other": touched every ~4 days, small amounts, plus one huge one.
        let body: [Double] = [25_000, 30_000, 50_000, 84_000, 100_000, 120_000,
                              150_000, 190_000, 200_000, 210_000, 300_000, 500_000]
        for (i, v) in body.enumerated() { history.append(tx(v, .other, daysAgo: 60 - i * 5)) }
        let stnk = tx(2_000_000, .other, daysAgo: 1, name: "STNK")
        history.append(stnk)
        let r = rhythm(history)
        XCTAssertEqual(r.autoVerdict(for: stnk, amount: 2_000_000), .outlier)
        // …and the ordinary members of the same category stay in.
        XCTAssertEqual(r.autoVerdict(for: tx(50_000, .other, daysAgo: 2), amount: 50_000),
                       .dayToDay)
    }

    // MARK: Degenerate inputs

    func testIdenticalAmountsDoNotDivideByZero() {
        var history = spread(200, 25_000, .food, over: 60)
        // MAD is zero when every amount matches; the engine must not produce a
        // verdict from a division by it.
        for i in 0..<12 { history.append(tx(100_000, .other, daysAgo: 60 - i * 5)) }
        let r = rhythm(history)
        XCTAssertEqual(r.autoVerdict(for: tx(100_000, .other, daysAgo: 1), amount: 100_000),
                       .dayToDay)
    }

    func testTooFewSamplesSkipOutlierTest() {
        var history = spread(200, 25_000, .food, over: 60)
        // Four "Other" rows: a cadence in the judged band but no distribution
        // worth testing against.
        for i in 0..<4 { history.append(tx(50_000, .other, daysAgo: 20 - i * 5)) }
        let r = rhythm(history)
        XCTAssertEqual(r.autoVerdict(for: tx(9_000_000, .other, daysAgo: 1), amount: 9_000_000),
                       .dayToDay)
    }

    // MARK: The user always wins

    func testOverrideBeatsTheEngineInBothDirections() {
        var history = spread(200, 25_000, .food, over: 60)
        let ticket = tx(800_000, .travel, daysAgo: 3)
        history += spread(4, 775_000, .travel, over: 60) + [ticket]
        let r = rhythm(history)

        ticket.oneOffOverride = false          // "no, this IS day-to-day"
        XCTAssertEqual(r.verdict(for: ticket, amount: 800_000), .dayToDay)

        let coffee = tx(25_000, .food, daysAgo: 1)
        coffee.oneOffOverride = true           // "no, this was a one-off"
        XCTAssertEqual(r.verdict(for: coffee, amount: 25_000), .userMarked)
    }

    func testNilOverrideMeansTrustTheEngine() {
        var history = spread(200, 25_000, .food, over: 60)
        let ticket = tx(800_000, .travel, daysAgo: 3)
        history += spread(4, 775_000, .travel, over: 60) + [ticket]
        let r = rhythm(history)
        ticket.oneOffOverride = true
        ticket.oneOffOverride = nil            // back to automatic
        XCTAssertEqual(r.verdict(for: ticket, amount: 800_000), .episodicCategory)
    }
}
