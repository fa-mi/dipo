import XCTest
@testable import DiPo

/// The Investment menu shows the user their money — a wrong cost-average or P/L
/// is worse than no feature. These pin the weighted-average maths that every
/// instrument shares, using the user's own gold example as the first case.
final class PortfolioEngineTests: XCTestCase {

    private func d(_ day: Int) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 9, day: day))!
    }

    // MARK: Weighted-average cost (the "harga rata-rata" the user asked for)

    func testGoldWeightedAverageAndUnrealizedGain() {
        // Buy 5 g @ 1,000,000 then 2 g @ 1,100,000 → avg 1,028,571.43/g over 7 g.
        let lots = [
            LotFact(date: d(1), kind: "buy", units: 5, pricePerUnit: 1_000_000),
            LotFact(date: d(2), kind: "buy", units: 2, pricePerUnit: 1_100_000),
        ]
        let s = PortfolioEngine.stats(lots: lots, lastPrice: 1_050_000, prevClose: 1_040_000)
        XCTAssertEqual(s.unitsHeld, 7, accuracy: 1e-9)
        XCTAssertEqual(s.avgCost, 7_200_000.0 / 7.0, accuracy: 0.01)
        XCTAssertEqual(s.costBasis, 7_200_000, accuracy: 0.01)
        XCTAssertEqual(s.marketValue, 7 * 1_050_000, accuracy: 0.01)     // 7,350,000
        XCTAssertEqual(s.unrealizedPL, 150_000, accuracy: 0.01)          // 7,350,000 − 7,200,000
        XCTAssertEqual(s.unrealizedPct, 150_000.0 / 7_200_000.0, accuracy: 1e-6)
        XCTAssertEqual(s.todayChange, 7 * 10_000, accuracy: 0.01)        // (1,050,000 − 1,040,000) × 7
    }

    /// A fee on the buy raises the cost basis (and the average).
    func testBuyFeeRaisesCostBasis() {
        let lots = [LotFact(date: d(1), kind: "buy", units: 100, pricePerUnit: 1_000, fee: 5_000)]
        let s = PortfolioEngine.stats(lots: lots, lastPrice: 1_000)
        XCTAssertEqual(s.costBasis, 105_000, accuracy: 0.01)
        XCTAssertEqual(s.avgCost, 1_050, accuracy: 0.01)
        XCTAssertEqual(s.unrealizedPL, -5_000, accuracy: 0.01)           // paid the fee, price flat
    }

    // MARK: Selling

    func testSellRealisesGainAndLeavesAverageUnchanged() {
        let lots = [
            LotFact(date: d(1), kind: "buy",  units: 10, pricePerUnit: 1_000),
            LotFact(date: d(2), kind: "buy",  units: 10, pricePerUnit: 2_000),   // avg now 1,500
            LotFact(date: d(3), kind: "sell", units: 5,  pricePerUnit: 2_500),   // realise vs 1,500
        ]
        let s = PortfolioEngine.stats(lots: lots, lastPrice: 2_000)
        XCTAssertEqual(s.unitsHeld, 15, accuracy: 1e-9)
        XCTAssertEqual(s.avgCost, 1_500, accuracy: 0.01)                 // unchanged by the sale
        XCTAssertEqual(s.realizedPL, 5 * (2_500 - 1_500), accuracy: 0.01) // +5,000
        XCTAssertEqual(s.costBasis, 15 * 1_500, accuracy: 0.01)          // 22,500
        XCTAssertEqual(s.unrealizedPL, 15 * (2_000 - 1_500), accuracy: 0.01) // +7,500
    }

    func testFullExitZeroesTheHolding() {
        let lots = [
            LotFact(date: d(1), kind: "buy",  units: 3, pricePerUnit: 100),
            LotFact(date: d(2), kind: "sell", units: 3, pricePerUnit: 120),
        ]
        let s = PortfolioEngine.stats(lots: lots, lastPrice: 120)
        XCTAssertEqual(s.unitsHeld, 0, accuracy: 1e-9)
        XCTAssertEqual(s.costBasis, 0, accuracy: 1e-9)
        XCTAssertEqual(s.unrealizedPL, 0, accuracy: 1e-9)
        XCTAssertEqual(s.realizedPL, 60, accuracy: 0.01)                 // 3 × (120 − 100)
    }

    // MARK: Income

    func testDividendAndCouponCountAsIncomeNotUnits() {
        let lots = [
            LotFact(date: d(1), kind: "buy", units: 100, pricePerUnit: 1_000),
            LotFact(date: d(5), kind: "dividend", cashAmount: 25_000),
            LotFact(date: d(6), kind: "coupon", cashAmount: 15_000),
        ]
        let s = PortfolioEngine.stats(lots: lots, lastPrice: 1_000)
        XCTAssertEqual(s.unitsHeld, 100, accuracy: 1e-9)
        XCTAssertEqual(s.income, 40_000, accuracy: 0.01)
        XCTAssertEqual(s.unrealizedPL, 0, accuracy: 0.01)
        XCTAssertEqual(s.totalReturn, 40_000, accuracy: 0.01)           // income only, price flat
    }

    // MARK: Portfolio aggregation across currencies

    func testPortfolioConvertsPerHoldingCurrency() {
        // Gold in IDR + one crypto holding priced in USD.
        let gold = PortfolioEngine.stats(
            lots: [LotFact(date: d(1), kind: "buy", units: 1, pricePerUnit: 1_000_000)],
            lastPrice: 1_100_000)                                        // +100,000 IDR
        let btc = PortfolioEngine.stats(
            lots: [LotFact(date: d(1), kind: "buy", units: 0.01, pricePerUnit: 60_000)],
            lastPrice: 65_000)                                           // +50 USD

        let convert: (Double, String, String) -> Double = { amt, from, to in
            (from == "USD" && to == "IDR") ? amt * 16_000 : amt
        }
        let t = PortfolioEngine.portfolio(
            [("gold", "IDR", gold), ("crypto", "USD", btc)],
            targetCurrency: "IDR", convert: convert)

        // marketValue: 1,100,000 IDR + (0.01 × 65,000 = 650 USD × 16,000) = 1,100,000 + 10,400,000
        XCTAssertEqual(t.marketValue, 1_100_000 + 650 * 16_000, accuracy: 0.5)
        // unrealized: 100,000 IDR + (50 USD × 16,000 = 800,000)
        XCTAssertEqual(t.unrealizedPL, 100_000 + 50 * 16_000, accuracy: 0.5)
        XCTAssertEqual(t.valueByType["crypto"] ?? 0, 650 * 16_000, accuracy: 0.5)
        XCTAssertEqual(t.valueByType["gold"] ?? 0, 1_100_000, accuracy: 0.5)
    }

    // MARK: Deposit (fixed price = amount in)

    func testFixedPriceDepositHasNoGain() {
        // Deposit modelled as units == rupiah, price fixed at 1.0.
        let s = PortfolioEngine.stats(
            lots: [LotFact(date: d(1), kind: "buy", units: 10_000_000, pricePerUnit: 1)],
            lastPrice: 1)
        XCTAssertEqual(s.marketValue, 10_000_000, accuracy: 0.01)
        XCTAssertEqual(s.unrealizedPL, 0, accuracy: 0.01)
    }
}
