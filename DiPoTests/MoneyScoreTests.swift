import XCTest
@testable import DiPo

/// The money score judges what happened, not what hasn't been spent yet.
@MainActor
final class MoneyScoreTests: XCTestCase {

    private func tx(_ amount: Double, daysAgo: Double, _ cat: TxCategory, subtype: TxSubtype = .normal,
                    name: String = "x") -> TxRecord {
        TxRecord(name: name, date: Date().addingTimeInterval(-daysAgo * 86_400), amount: amount,
                 type: "tx.type.purchase", icon: "circle", iconBgHex: cat.iconBg, category: cat,
                 currency: "IDR", subtype: subtype)
    }

    private func analyze(_ txs: [TxRecord], cycle: RecoCycleSnapshot) -> SmartRecommendation {
        SmartRecommendationEngine.analyze(transactions: txs, monthlyIncome: 10_000_000, goals: [], debts: [],
                                          currency: "IDR", currentCycle: cycle)
    }

    /// Eleven days after payday, Rp 5,9 jt spent, nothing saved or invested:
    /// the 41% not spent YET used to read as "Saving: Great, Investing: High, 100".
    func testUnspentSoFarIsNotSavedOrInvested() {
        let txs = [tx(-4_000_000, daysAgo: 8, .food), tx(-1_900_000, daysAgo: 5, .shopping)]
        let cycle = RecoCycleSnapshot(daily: 4_000_000, lifestyle: 1_900_000, investDebt: 0, savingsDeposits: 0,
                                      income: 10_000_000, elapsedFraction: 11.0 / 30.0)
        let r = analyze(txs, cycle: cycle)
        XCTAssertNotEqual(r.savingHabit, .great)
        XCTAssertEqual(r.investmentPotential, .poor, "nothing went to investing or debt")
        XCTAssertLessThan(r.smartScore, 60)
    }

    /// Paying Rp 2 jt off a card is 20% of income toward debt: it counts.
    func testDebtPaymentCountsAsInvestingAndDebt() {
        let txs = [tx(-1_500_000, daysAgo: 8, .food), tx(-2_000_000, daysAgo: 2, .debtPayment)]
        let cycle = RecoCycleSnapshot(daily: 1_500_000, lifestyle: 0, investDebt: 2_000_000, savingsDeposits: 0,
                                      income: 10_000_000, elapsedFraction: 11.0 / 30.0)
        XCTAssertEqual(analyze(txs, cycle: cycle).investmentPotential, .good)
    }

    /// A finished period that left 40% unspent still earns its saving grade.
    func testACompletePeriodsLeftoverStillCounts() {
        let txs = [tx(-5_000_000, daysAgo: 20, .food), tx(-1_000_000, daysAgo: 10, .shopping)]
        let cycle = RecoCycleSnapshot(daily: 5_000_000, lifestyle: 1_000_000, investDebt: 0, savingsDeposits: 0,
                                      income: 10_000_000, elapsedFraction: 1)
        XCTAssertEqual(analyze(txs, cycle: cycle).savingHabit, .great)
    }

    func testWithdrawalsAreNotIncome() {
        XCTAssertTrue(DataIntegrityCheck.isLikelyWithdrawal(tx(1_800_000, daysAgo: 3, .investment,
                                                               name: "tarik investasi bitcoin")))
        XCTAssertTrue(DataIntegrityCheck.isLikelyWithdrawal(tx(500_000, daysAgo: 3, .incomeOther,
                                                               name: "ambil tabungan")))
        XCTAssertFalse(DataIntegrityCheck.isLikelyWithdrawal(tx(10_000_000, daysAgo: 3, .salary, name: "Gaji")))
        XCTAssertFalse(DataIntegrityCheck.isLikelyWithdrawal(tx(-50_000, daysAgo: 3, .food, name: "tabungan")))
    }
}
