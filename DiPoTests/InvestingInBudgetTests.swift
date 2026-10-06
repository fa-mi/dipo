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

    /// Unspent money, Invest & Debt worked out as one pot: debt instalments
    /// still due come first, investing gets what the share leaves after them.
    func testUnspentMoneyPaysDebtFirstThenInvests() {
        let sb = SmartBudgetManager.shared
        let idr = { (v: Double) in CurrencyManager.shared.formatted(v, currency: "IDR") }
        LanguageManager.shared.withLanguage(.english) {
            // Rp 10 jt income, 20% share = Rp 2 jt; Rp 1,5 jt of instalments due, none paid.
            let both = sb.surplusInsight(unspent: 4_072_500, debtPaid: 0, invested: 0, debtDue: 1_500_000,
                                         income: 10_000_000, investShare: 0.20, currency: "IDR")
            XCTAssertTrue(both.title.contains(idr(4_072_500)))
            XCTAssertTrue(both.body.contains(idr(1_500_000)), both.body)   // debt first
            XCTAssertTrue(both.body.contains(idr(500_000)), both.body)     // then the rest of the 2 jt
            XCTAssertNotNil(both.action)

            // Instalments bigger than the share: all of it goes to debt, nothing to invest.
            let debtOnly = sb.surplusInsight(unspent: 4_000_000, debtPaid: 0, invested: 0, debtDue: 2_500_000,
                                             income: 10_000_000, investShare: 0.20, currency: "IDR")
            XCTAssertEqual(debtOnly.body, String(format: loc("insight.surplus_debt_body"), idr(2_500_000)))

            // Debt already paid this period: the rest of the share goes to investing.
            let investOnly = sb.surplusInsight(unspent: 4_000_000, debtPaid: 1_500_000, invested: 0,
                                               debtDue: 1_500_000, income: 10_000_000, investShare: 0.20,
                                               currency: "IDR")
            XCTAssertTrue(investOnly.body.contains(idr(500_000)), investOnly.body)

            // Less left than owed: the debt gets what there is.
            let thin = sb.surplusInsight(unspent: 300_000, debtPaid: 0, invested: 0, debtDue: 1_500_000,
                                         income: 10_000_000, investShare: 0.20, currency: "IDR")
            XCTAssertEqual(thin.body, String(format: loc("insight.surplus_debt_body"), idr(300_000)))

            // Nothing due and the share met: just the surplus.
            let met = sb.surplusInsight(unspent: 1_000_000, debtPaid: 0, invested: 2_500_000, debtDue: 0,
                                        income: 10_000_000, investShare: 0.20, currency: "IDR")
            XCTAssertNil(met.action)
        }
    }

    func testNewStringsInBothLanguages() {
        for key in ["tx.note.invest_buy", "reco.item.invest_keep_title", "reco.item.invest_keep_sub",
                    "reco.item.invest_more_title", "reco.item.invest_more_sub",
                    "insight.invest_over_title", "insight.invest_over_body",
                    "insight.surplus_ratio_body", "insight.lifestyle_first_cut",
                    "insight.surplus_debt_invest_body", "insight.surplus_debt_body",
                    "insight.review_lifestyle_first"] {
            XCTAssertNotEqual(loc(key), key, key)
        }
    }
}
