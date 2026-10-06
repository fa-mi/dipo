import XCTest
@testable import DiPo

/// Investing as Smart Budget and the recommendations see it: a purchase from a
/// card fills the Invest & Debt pot, and the advice knows what is already put in.
@MainActor
final class InvestingInBudgetTests: XCTestCase {

    private func tx(_ amount: Double, _ cat: TxCategory, subtype: TxSubtype = .normal,
                    notes: String = "") -> TxRecord {
        TxRecord(name: "x", date: .now, amount: amount, type: "tx.type.purchase", icon: "circle",
                 iconBgHex: cat.iconBg, category: cat, currency: "IDR", notes: notes, subtype: subtype)
    }

    func testInvestmentPurchaseFillsTheInvestPotNotDailyOrLifestyle() {
        let start = Calendar.current.startOfDay(for: .now)
        let buy = tx(-2_000_000, .investment, notes: "tx.note.invest_buy")
        let sb = SmartBudgetManager.shared
        XCTAssertEqual(sb.spent(in: .investDebt, transactions: [buy], targetCurrency: "IDR", periodStart: start),
                       2_000_000, accuracy: 0.01)
        XCTAssertEqual(sb.spent(in: .daily, transactions: [buy], targetCurrency: "IDR", periodStart: start), 0)
        XCTAssertEqual(sb.spent(in: .lifestyle, transactions: [buy], targetCurrency: "IDR", periodStart: start), 0)
    }

    func testOnlyTheOldPurchaseShapeIsReclassified() {
        XCTAssertTrue(InvestmentCash.isLegacyOutflow(tx(-500_000, .other, subtype: .transfer)))
        // Recategorised by the user since, or not an outflow: left alone.
        XCTAssertFalse(InvestmentCash.isLegacyOutflow(tx(-500_000, .shopping, subtype: .transfer)))
        XCTAssertFalse(InvestmentCash.isLegacyOutflow(tx(-500_000, .other)))
        XCTAssertFalse(InvestmentCash.isLegacyOutflow(tx(500_000, .other, subtype: .transfer)))
    }

    func testInvestCardFitsWhatIsAlreadyInvested() {
        XCTAssertEqual(InvestPitch.make(suggested: 1_000_000, investedMonthly: 0, portfolioValue: 0), .start)
        XCTAssertEqual(InvestPitch.make(suggested: 1_000_000, investedMonthly: 0, portfolioValue: 80_000_000),
                       .keepGoing)
        XCTAssertEqual(InvestPitch.make(suggested: 1_000_000, investedMonthly: 400_000, portfolioValue: 0),
                       .topUp(600_000))
        // Close enough to the plan: no card.
        XCTAssertNil(InvestPitch.make(suggested: 1_000_000, investedMonthly: 850_000, portfolioValue: 0))
        XCTAssertNil(InvestPitch.make(suggested: 0, investedMonthly: 0, portfolioValue: 0))
    }

    func testInvestingAbovePlanIsOnlyFlaggedWhenItOutrunsIncome() {
        // Rp 4 jt income, Rp 2,5 jt living, Rp 1 jt invested: above a 20% plan, but it fits.
        XCTAssertNil(SmartBudgetManager.investingShortfall(invested: 1_000_000, consumed: 2_500_000,
                                                           income: 4_000_000))
        // A Rp 2 jt gold purchase in the same month leaves Rp 500 rb uncovered.
        XCTAssertEqual(SmartBudgetManager.investingShortfall(invested: 2_000_000, consumed: 2_500_000,
                                                             income: 4_000_000) ?? 0,
                       500_000, accuracy: 0.01)
        XCTAssertNil(SmartBudgetManager.investingShortfall(invested: 1, consumed: 0, income: 0))
    }

    /// Moving money to another account or paying a card bill isn't spending:
    /// a transfer must not change the advice. It did — "still unspent" read
    /// Rp 1,4 jt on a report whose "Left" said Rp 4 jt.
    func testATransferDoesNotChangeTheInsight() {
        let start = Calendar.current.date(byAdding: .day, value: -10, to: .now)!
        let spending = [tx(-1_200_000, .food), tx(-1_650_000, .commitment), tx(-420_000, .bills)]
        let withTransfer = spending + [tx(-2_650_000, .other, subtype: .transfer)]
        let sb = SmartBudgetManager.shared
        let plain = sb.topInsight(allTransactions: spending, income: 10_000_000,
                                  targetCurrency: "IDR", periodStart: start)
        let moved = sb.topInsight(allTransactions: withTransfer, income: 10_000_000,
                                  targetCurrency: "IDR", periodStart: start)
        XCTAssertEqual(plain?.title, moved?.title)
        XCTAssertEqual(plain?.body, moved?.body)
    }

    func testNewStringsInBothLanguages() {
        for key in ["tx.note.invest_buy", "reco.item.invest_keep_title", "reco.item.invest_keep_sub",
                    "reco.item.invest_more_title", "reco.item.invest_more_sub",
                    "insight.invest_over_title", "insight.invest_over_body"] {
            XCTAssertNotEqual(loc(key), key, key)
        }
    }
}
