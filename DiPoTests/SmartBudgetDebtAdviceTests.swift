import XCTest
@testable import DiPo

/// Smart Budget's card on the Debts screen, told how a usual month really
/// goes and what others still owe.
///
/// Fahmi's screen on 18 Oct: "Debt: Too heavy" — a usual month Rp 2.102.467
/// short — and right under it Smart Budget advised an extra Rp 383.333 on the
/// card, money the month does not have. And nothing said what to do with the
/// money people owed him.
@MainActor
final class SmartBudgetDebtAdviceTests: XCTestCase {

    private func english<T>(_ body: () -> T) -> T { LanguageManager.shared.withLanguage(.english, body) }

    /// Rp 1.500.000 set aside, Rp 1.116.667 in minimums, Rp 5.250.000 carried.
    private func fahmi(monthLeft: Double?, owed: Double = 0) -> DebtFirstAdvice {
        var a = DebtFirstAdvice(share: 1_500_000, ratio: 0.15, minimums: 1_116_667,
                                target: .card(carried: 5_250_000))
        a.monthLeft = monthLeft
        a.owedToYou = owed
        return a
    }

    // MARK: A month that runs short

    func testAShortMonthClosesTheGapBeforeAnyExtraPayment() {
        let a = fahmi(monthLeft: -2_102_467)
        XCTAssertTrue(a.closeTheGapFirst)
        XCTAssertEqual(a.shortfall, 2_102_467, accuracy: 0.5)
        XCTAssertEqual(a.extra, 0, "the Rp 383.333 is not there")
        XCTAssertEqual(a.plannedExtra, 383_333, accuracy: 0.5)
        english {
            XCTAssertEqual(a.title(), "First spend less, then pay the card")
            let share = a.shareLine(currency: "IDR") ?? ""
            XCTAssertTrue(share.contains("2.102.467") && share.contains("1.500.000"), share)
            let body = a.body(currency: "IDR")
            XCTAssertTrue(body.contains("5.250.000"), body)
            XCTAssertFalse(body.contains("goes back to saving"), body)
        }
    }

    func testCheapDebtsInAShortMonthPointAtTheSpending() {
        var a = DebtFirstAdvice(share: 1_500_000, ratio: 0.15, minimums: 854_167, target: nil)
        a.monthLeft = -500_000
        english {
            XCTAssertEqual(a.title(), "First, spend less")
            XCTAssertEqual(a.body(currency: "IDR"), loc("debt.first.gap_cheap"))
        }
        a.owedToYou = 3_000_000
        let body = english { a.body(currency: "IDR") }
        XCTAssertTrue(body.contains("3.000.000") && body.contains("once, not every month"), body)
    }

    // MARK: A month with a little left

    /// The extra is what a usual month leaves, never more than the plan.
    func testTheExtraIsWhatAUsualMonthLeaves() {
        let tight = fahmi(monthLeft: 200_000)
        XCTAssertFalse(tight.closeTheGapFirst)
        XCTAssertEqual(tight.extra, 200_000, accuracy: 0.5)
        XCTAssertTrue(tight.extraCapped)
        let body = english { tight.body(currency: "IDR") }
        XCTAssertTrue(body.contains("only have Rp 200.000 left"), body)

        let roomy = fahmi(monthLeft: 2_000_000)
        XCTAssertEqual(roomy.extra, 383_333, accuracy: 0.5)
        XCTAssertFalse(roomy.extraCapped)
        XCTAssertEqual(fahmi(monthLeft: nil).extra, 383_333, accuracy: 0.5, "no income to weigh: the plan stands")
    }

    func testAPayoffDateUsesWhatTheMonthCanReallyPay() throws {
        var a = DebtFirstAdvice(share: 1_500_000, ratio: 0.15, minimums: 900_000,
                                target: .debt(name: "Kredivo", annualRate: 36, balance: 10_000_000, minimum: 500_000))
        a.monthLeft = 300_000
        let p = try XCTUnwrap(a.faster())
        XCTAssertEqual(p.fast.months, 16, "Rp 500 rb + the Rp 300 rb the month leaves, not the plan's Rp 600 rb")
    }

    // MARK: Money owed back

    func testMoneyOwedBackGoesOnTheCardBalanceFirst() {
        let all = english { fahmi(monthLeft: -2_102_467, owed: 6_000_000).body(currency: "IDR") }
        XCTAssertTrue(all.contains("6.000.000") && all.contains("covers all of it"), all)
        XCTAssertTrue(all.contains("When it comes back"), "money owed is used once it is back, never before: \(all)")
        XCTAssertTrue(all.hasSuffix(english { loc("debt.first.no_lending") }), all)

        let part = english { fahmi(monthLeft: 1_000_000, owed: 2_000_000).body(currency: "IDR") }
        XCTAssertTrue(part.contains("2.000.000") && part.contains("5.250.000"), part)
        XCTAssertFalse(part.contains("covers all of it"), part)

        let none = english { fahmi(monthLeft: 1_000_000).body(currency: "IDR") }
        XCTAssertFalse(none.contains("owe you"), none)
    }

    func testMoneyOwedBackIsNamedWhenTheMinimumsTakeTheWholeShare() {
        var a = DebtFirstAdvice(share: 1_500_000, ratio: 0.15, minimums: 1_700_000,
                                target: .card(carried: 5_250_000))
        a.owedToYou = 1_000_000
        let body = english { a.body(currency: "IDR") }
        XCTAssertTrue(body.contains("1.700.000") && body.contains("owe you Rp 1.000.000"), body)
    }

    // MARK: Words

    func testTheNewStringsExistInBothLanguagesAndKeepTheirArguments() {
        let keys = ["debt.first.title_gap", "debt.first.title_gap_card", "debt.first.title_gap_debt", "debt.first.gap",
                    "debt.first.gap_cheap", "debt.first.row_after_gap", "debt.first.capped", "debt.first.owed_clears",
                    "debt.first.owed_part", "debt.first.owed_buffer", "debt.first.no_lending"]
        for language in [LanguageManager.Language.english, .indonesian] {
            LanguageManager.shared.withLanguage(language) {
                for k in keys { XCTAssertNotEqual(loc(k), k, "\(k) in \(language)") }
                let gap = String(format: loc("debt.first.gap"), "Rp A", "Rp B")
                XCTAssertTrue(gap.contains("Rp A") && gap.contains("Rp B"), gap)
                let part = String(format: loc("debt.first.owed_part"), "Rp A", "kartu", "Rp C")
                XCTAssertTrue(part.contains("Rp A") && part.contains("kartu") && part.contains("Rp C"), part)
            }
        }
    }
}
