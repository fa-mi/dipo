import XCTest
@testable import DiPo

/// A DPLK pension fund (BRIFINE and the like) as its own investment type:
/// entered as rupiah in and rupiah now, and kept apart from money to hand.
@MainActor
final class PensionFundTests: XCTestCase {

    func testPensionIsAmountBasedLockedAndNotAutoPriced() {
        let t = InvestmentType.pension
        XCTAssertTrue(t.isAmountBased)
        XCTAssertTrue(t.isLocked)
        XCTAssertFalse(t.supportsAutoPrice)
        XCTAssertFalse(t.priceIsFixed)
        XCTAssertEqual(t.cadence, .monthly)
        XCTAssertEqual(InvestmentType(rawValue: "pension"), .pension)
        XCTAssertEqual(InvestmentType.allCases.filter(\.isLocked), [.pension])
    }

    func testBrifineFiguresGiveItsBalanceAndReturn() {
        // BRIFINE: Saldo Rp48.126.522,45, Imbal Hasil Rp3.736.394,02 (+8,42%).
        let saldo = 48_126_522.45, imbal = 3_736_394.02
        let contributed = saldo - imbal
        let ratio = InvestmentType.pension.openingRatio(amount: contributed, valueNow: saldo)
        let s = PortfolioEngine.stats(lots: [LotFact(date: .now, kind: "buy", units: contributed, pricePerUnit: 1)],
                                      lastPrice: ratio)
        XCTAssertEqual(s.marketValue, saldo, accuracy: 0.01)
        XCTAssertEqual(s.unrealizedPL, imbal, accuracy: 0.01)
        XCTAssertEqual(s.unrealizedPct * 100, 8.42, accuracy: 0.005)
    }

    func testEmptyValueNowKeepsWhatWentIn() {
        // Used to save at Rp 0 when "Value now" was left blank.
        XCTAssertEqual(InvestmentType.bond.openingRatio(amount: 10_000_000, valueNow: 0), 1)
        XCTAssertEqual(InvestmentType.pension.openingRatio(amount: 10_000_000, valueNow: 0), 1)
        XCTAssertEqual(InvestmentType.deposit.openingRatio(amount: 10_000_000, valueNow: 12_000_000), 1)
        XCTAssertEqual(InvestmentType.bond.openingRatio(amount: 10_000_000, valueNow: 10_500_000), 1.05, accuracy: 1e-9)
    }

    func testPensionStaysInTheTotalByType() {
        let stock = PortfolioEngine.stats(lots: [LotFact(date: .now, kind: "buy", units: 100, pricePerUnit: 3_000)],
                                          lastPrice: 3_000)
        let pension = PortfolioEngine.stats(lots: [LotFact(date: .now, kind: "buy", units: 1_000_000, pricePerUnit: 1)],
                                            lastPrice: 1)
        let t = PortfolioEngine.portfolio([(type: "stock", currency: "IDR", stats: stock),
                                           (type: "pension", currency: "IDR", stats: pension)],
                                          targetCurrency: "IDR", convert: { v, _, _ in v })
        XCTAssertEqual(t.marketValue, 1_300_000, accuracy: 0.01)
        XCTAssertEqual(t.valueByType["pension"] ?? 0, 1_000_000, accuracy: 0.01)
    }

    func testTinySliceReadsLessThanOnePercent() {
        XCTAssertEqual(allocationShareLabel(9, of: 1_000), "<1%")
        XCTAssertEqual(allocationShareLabel(0, of: 1_000), "0%")
        XCTAssertEqual(allocationShareLabel(586, of: 1_000), "59%")
        XCTAssertEqual(allocationShareLabel(1, of: 0), "0%")
    }

    func testPensionStringsInBothLanguages() {
        for key in ["invest.type.pension", "invest.cadence.monthly", "invest.field.contributed",
                    "invest.field.contributed_hint", "invest.field.pension_value_hint",
                    "invest.liquid", "invest.locked_pension", "invest.status.summary_one",
                    "invest.value_chart"] {
            XCTAssertNotEqual(loc(key), key, key)
        }
    }
}
