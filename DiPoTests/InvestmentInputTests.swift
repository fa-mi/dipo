import XCTest
@testable import DiPo

/// What the investment forms make of typed numbers. Every case here is a
/// number someone really copies from a finance app: BRImo's gold balance,
/// Gotrade's fractional shares, rupiah prices with dot grouping.
final class InvestmentInputTests: XCTestCase {

    // MARK: Reading numbers

    func testIndonesianGroupingAndDecimals() {
        XCTAssertEqual(InvestmentInput.number("1.000.000"), 1_000_000)
        XCTAssertEqual(InvestmentInput.number("200.000"), 200_000)
        XCTAssertEqual(InvestmentInput.number("16.160"), 16_160)
        XCTAssertEqual(InvestmentInput.number("2.251.774"), 2_251_774)
        XCTAssertEqual(InvestmentInput.number("0,1308"), 0.1308, accuracy: 1e-12)
        XCTAssertEqual(InvestmentInput.number("1.234.567,89"), 1_234_567.89, accuracy: 1e-6)
        XCTAssertEqual(InvestmentInput.number("Rp 308.426"), 308_426, "a currency marker copied along is ignored")
        XCTAssertEqual(InvestmentInput.number(" 308 426 "), 308_426)
    }

    /// The bug: a single dot followed by more than two digits was always read
    /// as grouping, so 0.134582962 shares became 134,582,962.
    func testDotDecimalsFromForeignApps() {
        XCTAssertEqual(InvestmentInput.number("0.134582962"), 0.134582962, accuracy: 1e-12)
        XCTAssertEqual(InvestmentInput.number("0.1308"), 0.1308, accuracy: 1e-12)
        XCTAssertEqual(InvestmentInput.number("0.080"), 0.08, accuracy: 1e-12)
        XCTAssertEqual(InvestmentInput.number("366.51"), 366.51, accuracy: 1e-9)
        XCTAssertEqual(InvestmentInput.number("381.8"), 381.8, accuracy: 1e-9)
        XCTAssertEqual(InvestmentInput.number("1.5"), 1.5, accuracy: 1e-12)
        XCTAssertEqual(InvestmentInput.number("2.2517"), 2.2517, accuracy: 1e-12)
    }

    func testEnglishGrouping() {
        XCTAssertEqual(InvestmentInput.number("1,234.56"), 1_234.56, accuracy: 1e-9)
        XCTAssertEqual(InvestmentInput.number("1,000,000"), 1_000_000)
    }

    func testRejectsJunk() {
        XCTAssertEqual(InvestmentInput.number(""), 0)
        XCTAssertEqual(InvestmentInput.number("abc"), 0)
        XCTAssertEqual(InvestmentInput.number("-5"), 0)
    }

    func testTextRoundTrips() {
        for v in [0.1308, 0.134582962, 0.00001, 366.51, 2_251_774, 16_160, 0.005, 1] {
            let t = InvestmentInput.text(v)
            XCTAssertFalse(t.contains("e"), "no scientific notation: \(t)")
            XCTAssertEqual(InvestmentInput.number(t), v, accuracy: 1e-9, t)
        }
        XCTAssertEqual(InvestmentInput.text(0.1308), "0,1308")
        XCTAssertEqual(InvestmentInput.text(2_251_774), "2251774")
    }

    // MARK: Totals and per-unit prices

    /// The BRImo screen: 0,1308 g, balance Rp308.426, yield +Rp13.894.
    func testBRImoGoldBalanceAsTotals() {
        let grams = 0.1308
        let buy = InvestmentInput.perUnitPrice(294_532, units: grams, mode: .total)
        let now = InvestmentInput.perUnitPrice(308_426, units: grams, mode: .total)
        XCTAssertEqual(grams * buy, 294_532, accuracy: 0.01)
        XCTAssertEqual(now, 2_358_000, accuracy: 5)   // = Rp23.580 per 0,01 g × 100
        XCTAssertFalse(InvestmentInput.goldPriceLooksWrong(perGram: buy, currency: "IDR"))
        XCTAssertFalse(InvestmentInput.goldPriceLooksWrong(perGram: now, currency: "IDR"))

        let lots = [LotFact(date: .now, kind: "buy", units: grams, pricePerUnit: buy)]
        let s = PortfolioEngine.stats(lots: lots, lastPrice: now)
        XCTAssertEqual(s.marketValue, 308_426, accuracy: 1)
        XCTAssertEqual(s.unrealizedPL, 13_894, accuracy: 1)
        XCTAssertEqual(s.unrealizedPct, 0.0472, accuracy: 0.0001)
    }

    func testPerUnitModeKeepsThePriceAndTotalNeedsUnits() {
        XCTAssertEqual(InvestmentInput.perUnitPrice(381.88, units: 0.0339, mode: .perUnit), 381.88)
        XCTAssertEqual(InvestmentInput.perUnitPrice(12.43, units: 0, mode: .total), 0)
    }

    /// BRImo quotes "Rp23.580 /0,01 gram"; typed as it is, that is a gram's price.
    func testPerHundredthGramIsTheGoldAppQuote() {
        XCTAssertEqual(InvestmentInput.perUnitPrice(23_580, units: 0.1308, mode: .perHundredth), 2_358_000)
        XCTAssertEqual(InvestmentInput.entered(forUnitPrice: 2_358_000, units: 0.1308, mode: .perHundredth), 23_580)
        XCTAssertEqual(InvestmentInput.entered(forUnitPrice: 2_358_000, units: 0.1308, mode: .total),
                       308_426.4, accuracy: 0.01)
        XCTAssertEqual(InvestmentInput.PriceMode.standard, [.perUnit, .total])
    }

    /// Holdings saved before the forms caught it: the totals from the BRImo
    /// screen, recorded as prices per gram, come back as BRImo's own figures.
    func testRepairTurnsRecordedTotalsBackIntoGramPrices() throws {
        let grams = 0.1308
        let buy = try XCTUnwrap(InvestmentInput.repairedGoldPrice(294_532, grams: grams, currency: "IDR"))
        let now = try XCTUnwrap(InvestmentInput.repairedGoldPrice(308_426, grams: grams, currency: "IDR"))
        let s = PortfolioEngine.stats(lots: [LotFact(date: .now, kind: "buy", units: grams, pricePerUnit: buy)],
                                      lastPrice: now)
        XCTAssertEqual(s.marketValue, 308_426, accuracy: 1)
        XCTAssertEqual(s.unrealizedPL, 13_894, accuracy: 1)
        XCTAssertEqual(s.unrealizedPct, 0.0472, accuracy: 0.0001)
        // The second holding in the report: 0,0808 g "at Rp200.000".
        XCTAssertEqual(try XCTUnwrap(InvestmentInput.repairedGoldPrice(200_000, grams: 0.0808, currency: "IDR")),
                       2_475_247.5, accuracy: 1)
    }

    func testRepairLeavesWhatItCannotExplain() {
        // Already a gram price.
        XCTAssertNil(InvestmentInput.repairedGoldPrice(2_358_000, grams: 0.1308, currency: "IDR"))
        // Wrong, but dividing doesn't make it right either.
        XCTAssertNil(InvestmentInput.repairedGoldPrice(23_580, grams: 0.1308, currency: "IDR"))
        // Not rupiah, or nothing held.
        XCTAssertNil(InvestmentInput.repairedGoldPrice(140, grams: 1, currency: "USD"))
        XCTAssertNil(InvestmentInput.repairedGoldPrice(308_426, grams: 0, currency: "IDR"))
    }

    // MARK: Decimal slips

    /// The Apple holding in the report: bought at $223.06, recorded at 22306.
    func testLostDecimalIsCaughtAndSuggested() throws {
        XCTAssertEqual(try XCTUnwrap(InvestmentInput.priceSlip(22_306, reference: 333.69)), 223.06, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(InvestmentInput.priceSlip(22_306, reference: 223.06)), 223.06, accuracy: 1e-9)
        // The other way: a rupiah price typed with a stray decimal.
        XCTAssertEqual(try XCTUnwrap(InvestmentInput.priceSlip(43.6267, reference: 3_080)), 4_362.67, accuracy: 1e-6)
    }

    func testRealPriceMovesAreLeftAlone() {
        // Google at $191.73 bought, $340.35 now; BBRI at Rp4.362,67 bought, Rp3.080 now.
        XCTAssertNil(InvestmentInput.priceSlip(191.73, reference: 340.35))
        XCTAssertNil(InvestmentInput.priceSlip(4_362.67, reference: 3_080))
        // A genuine five-bagger is still under the 8× line.
        XCTAssertNil(InvestmentInput.priceSlip(500, reference: 100))
        // Far off, but shifting the decimal doesn't explain it either.
        XCTAssertNil(InvestmentInput.priceSlip(300_000, reference: 100))
        // Nothing to compare with.
        XCTAssertNil(InvestmentInput.priceSlip(22_306, reference: 0))
    }

    // MARK: Gold sanity

    func testTotalsTypedAsPerGramAreCaught() {
        // What was actually entered: the totals, as prices per gram.
        XCTAssertTrue(InvestmentInput.goldPriceLooksWrong(perGram: 294_532, currency: "IDR"))
        XCTAssertTrue(InvestmentInput.goldPriceLooksWrong(perGram: 308_426, currency: "IDR"))
        // A price per 0,01 gram.
        XCTAssertTrue(InvestmentInput.goldPriceLooksWrong(perGram: 23_580, currency: "IDR"))
        // Real per-gram prices, old and new.
        XCTAssertFalse(InvestmentInput.goldPriceLooksWrong(perGram: 1_000_000, currency: "IDR"))
        XCTAssertFalse(InvestmentInput.goldPriceLooksWrong(perGram: 2_358_000, currency: "IDR"))
        // Nothing typed yet, or not rupiah: no opinion.
        XCTAssertFalse(InvestmentInput.goldPriceLooksWrong(perGram: 0, currency: "IDR"))
        XCTAssertFalse(InvestmentInput.goldPriceLooksWrong(perGram: 140, currency: "USD"))
    }

    // MARK: Stock markets

    func testYahooTickerFollowsTheHoldingCurrency() {
        XCTAssertEqual(StockMarket.yahooTicker(symbol: "bbca", currency: "IDR"), "BBCA.JK")
        XCTAssertEqual(StockMarket.yahooTicker(symbol: " AAPL ", currency: "USD"), "AAPL")
        XCTAssertEqual(StockMarket.yahooTicker(symbol: "brk-b", currency: "USD"), "BRK-B")
        XCTAssertEqual(StockMarket.yahooTicker(symbol: "BBCA.JK", currency: "USD"), "BBCA.JK")
        XCTAssertEqual(StockMarket.of(currency: "idr"), .idx)
        XCTAssertEqual(StockMarket.of(currency: "USD"), .us)
        XCTAssertEqual(StockMarket.us.currency, "USD")
    }

    /// A US position is valued in dollars and only converted for the totals.
    func testUSPositionConvertsIntoRupiahTotals() {
        let visa = PortfolioEngine.stats(
            lots: [LotFact(date: .now, kind: "buy", units: 0.033937184, pricePerUnit: 381.88)],
            lastPrice: 366.51)
        XCTAssertEqual(visa.marketValue, 12.44, accuracy: 0.01)
        let totals = PortfolioEngine.portfolio(
            [(type: "stock", currency: "USD", stats: visa)],
            targetCurrency: "IDR",
            convert: { amount, from, to in from == "USD" && to == "IDR" ? amount * 16_000 : amount })
        XCTAssertEqual(totals.marketValue, visa.marketValue * 16_000, accuracy: 0.01)
    }
}

/// Gold can follow Pegadaian's price; nothing else about gold is auto-priced.
final class GoldFeedTests: XCTestCase {

    @MainActor
    func testRupiahGoldFollowsPegadaianWhenSwitchedOn() {
        let gold = InvestmentHolding(type: .gold, name: "Tring", currency: "IDR")
        XCTAssertTrue(gold.manualPrice, "gold starts by hand")
        XCTAssertFalse(gold.isAutoPriced)

        gold.setGoldFeed(true)
        XCTAssertEqual(gold.symbol, GoldFeed.symbol)
        XCTAssertFalse(gold.manualPrice)
        XCTAssertTrue(gold.isAutoPriced)
        XCTAssertTrue(gold.followsGoldFeed)

        // Pausing keeps which gold it is, so turning it back on resumes it.
        gold.setGoldFeed(false)
        XCTAssertFalse(gold.isAutoPriced)
        XCTAssertEqual(gold.symbol, GoldFeed.symbol)
    }

    @MainActor
    func testOnlyRupiahGoldCanFollowTheFeed() {
        let usd = InvestmentHolding(type: .gold, name: "XAU", currency: "USD")
        usd.setGoldFeed(true)
        XCTAssertFalse(usd.isAutoPriced)
        let fund = InvestmentHolding(type: .mutualFund, name: "RDPU", symbol: GoldFeed.symbol, currency: "IDR")
        fund.manualPrice = false
        XCTAssertFalse(fund.isAutoPriced)
        let stock = InvestmentHolding(type: .stock, name: "BBRI", symbol: "BBRI", currency: "IDR")
        XCTAssertTrue(stock.isAutoPriced, "stocks are unchanged")
    }
}
