import XCTest
@testable import DiPo

/// Plan opens on what is left to spend this period, then Needs, Wants and
/// Savings & debt as rows. Past a limit is orange, with by how much; going
/// past the savings target is never "over".
@MainActor
final class PlanBudgetTests: XCTestCase {

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func money(_ v: Double) -> String { CurrencyManager.shared.formatted(v, currency: "IDR") }

    private func budget(income: Double, needs: Double, wants: Double, saved: Double) -> PlanBudget? {
        PlanBudget.make(income: income, ratios: (daily: 0.5, lifestyle: 0.3, investDebt: 0.2), currency: "IDR") {
            switch $0 {
            case .daily: return needs
            case .lifestyle: return wants
            case .investDebt: return saved
            }
        }
    }

    func testLimitsAreSharesOfIncome() throws {
        let b = try XCTUnwrap(budget(income: 5_000_000, needs: 1_000_000, wants: 500_000, saved: 200_000))
        XCTAssertEqual(b.groups.map(\.group), [.daily, .lifestyle, .investDebt])
        XCTAssertEqual(b.groups.map(\.limit), [2_500_000, 1_500_000, 1_000_000])
    }

    func testLeftIsWhatNeedsAndWantsHaveLeft() throws {
        let b = try XCTUnwrap(budget(income: 5_000_000, needs: 1_000_000, wants: 500_000, saved: 900_000))
        XCTAssertEqual(b.left, 2_500_000, "savings are a target, not spending room")
        let past = try XCTUnwrap(budget(income: 5_000_000, needs: 3_000_000, wants: 1_700_000, saved: 0))
        XCTAssertEqual(past.left, -700_000)
    }

    func testOverOnlyPastALimitNeverPastTheTarget() throws {
        let b = try XCTUnwrap(budget(income: 5_000_000, needs: 2_800_000, wants: 100_000, saved: 1_400_000))
        XCTAssertEqual(b.groups[0].over, 300_000)
        XCTAssertEqual(b.groups[1].over, 0)
        XCTAssertEqual(b.groups[2].over, 0, "saving more than the target is good news")
    }

    func testNoIncomeNoBudgetAndRefundsDoNotGoBelowZero() throws {
        XCTAssertNil(budget(income: 0, needs: 1, wants: 1, saved: 1))
        let b = try XCTUnwrap(budget(income: 1_000_000, needs: -50_000, wants: 0, saved: 0))
        XCTAssertEqual(b.groups[0].spent, 0)
    }

    func testFiguresInWords() throws {
        let b = try XCTUnwrap(budget(income: 5_000_000, needs: 1_000_000, wants: 0, saved: 200_000))
        LanguageManager.shared.withLanguage(.indonesian) {
            XCTAssertEqual(PlanBudgetBlock.figure(b.groups[0], money: money),
                           "\(money(1_000_000)) dari \(money(2_500_000))")
            XCTAssertEqual(PlanBudgetBlock.figure(b.groups[2], money: money),
                           "\(money(200_000)) dari target \(money(1_000_000))")
            XCTAssertEqual(String(format: loc("plan.group_over"), money(300_000)), "Lebih \(money(300_000)) dari batas")
        }
    }

    func testOwedCountsActiveDebts() {
        let kur = DebtRecord(name: "KUR", type: "loan", totalAmount: 10_000_000, currentBalance: 6_000_000,
                             minimumPayment: 500_000, annualInterestRate: 6, dueDayOfMonth: 20, currency: "IDR")
        let done = DebtRecord(name: "Paylater", type: "loan", totalAmount: 1_000_000, currentBalance: 0,
                              minimumPayment: 0, annualInterestRate: 0, dueDayOfMonth: 5, currency: "IDR")
        done.isActive = false
        XCTAssertEqual(PlanRowValue.owed(debts: [kur, done], cards: [], installments: [], currency: "IDR"), 6_000_000)
    }

    func testNewStringsInBothLanguages() {
        for lang in LanguageManager.Language.allCases {
            LanguageManager.shared.withLanguage(lang) {
                for k in ["plan.budget_left", "plan.budget_over", "plan.group_of", "plan.group_over",
                          "plan.saved_of_target", "plan.bills_count"] {
                    XCTAssertNotEqual(loc(k), k, "\(k) in \(lang)")
                }
            }
        }
    }

    /// The block comes first on the tab, sits on the page, and is never green.
    func testTheBlockLeadsAndSitsOnThePage() throws {
        let plan = try String(contentsOf: root.appendingPathComponent("PlanView.swift"), encoding: .utf8)
        let block = try XCTUnwrap(plan.range(of: "PlanBudgetBlock(budget:"))
        let ladder = try XCTUnwrap(plan.range(of: "FinancialLadderCard("))
        XCTAssertLessThan(block.lowerBound, ladder.lowerBound)
        let src = try String(contentsOf: root.appendingPathComponent("DiPo/PlanBudget.swift"), encoding: .utf8)
        XCTAssertFalse(src.contains("AppTheme.cardDark, in:"))
        XCTAssertFalse(src.contains("accent"), "what is left to spend is not money coming in")
    }
}
