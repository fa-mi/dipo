import Foundation

// MARK: - Financial ladder
//
// The order money habits are usually built in, read from what DiPo already
// knows: spend within income, clear costly debt, hold three months of
// essentials, invest regularly, then provide for retirement and goals.
//
// It answers "am I ready to invest?" — the question most DiPo users actually
// have — rather than "which product should I buy", which is licensed advice
// (penasihat investasi, OJK) and not DiPo's to give. No product is ever named.
//
// Pure: the view gathers the inputs, this decides. Pinned by FinancialLadderTests.

enum LadderStep: Int, CaseIterable, Identifiable {
    case spending = 1, debt, emergency, investing, future
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .spending:  return loc("ladder.step.spending")
        case .debt:      return loc("ladder.step.debt")
        case .emergency: return loc("ladder.step.emergency")
        case .investing: return loc("ladder.step.investing")
        case .future:    return loc("ladder.step.future")
        }
    }

    /// Why this rung comes where it does — the literacy part.
    var why: String {
        switch self {
        case .spending:  return loc("ladder.why.spending")
        case .debt:      return loc("ladder.why.debt")
        case .emergency: return loc("ladder.why.emergency")
        case .investing: return loc("ladder.why.investing")
        case .future:    return loc("ladder.why.future")
        }
    }

    var icon: String {
        switch self {
        case .spending:  return "scalemass.fill"
        case .debt:      return "creditcard.trianglebadge.exclamationmark"
        case .emergency: return "shield.lefthalf.filled"
        case .investing: return "chart.line.uptrend.xyaxis"
        case .future:    return "beach.umbrella.fill"
        }
    }
}

struct LadderInputs: Equatable {
    /// Income per month (salary schedule, or what actually came in).
    var monthlyIncome: Double = 0
    /// Average monthly Daily needs + Lifestyle spending.
    var monthlyConsumption: Double = 0
    /// Average monthly Daily needs alone — what an emergency fund must cover.
    var monthlyEssentials: Double = 0
    /// The most expensive debt at or above `FinancialLadder.costlyRate`, if any.
    var costlyDebt: CostlyDebt? = nil
    /// Cash in (non-credit) cards and wallets.
    var cash: Double = 0
    /// Holdings that turn into cash within days without a big loss: deposits,
    /// and gold — which is how many households here keep their buffer.
    var liquidHoldings: Double = 0
    /// Average monthly money put into investments and savings goals.
    var investedMonthly: Double = 0
    /// Market value of holdings that aren't locked (pension excluded).
    var portfolioValue: Double = 0
    var pensionValue: Double = 0
    var activeGoals: Int = 0

    struct CostlyDebt: Equatable {
        var name: String
        var annualRate: Double
        var balance: Double
    }
}

struct LadderRung: Equatable, Identifiable {
    let step: LadderStep
    let done: Bool
    /// 0…1, how far along this rung is.
    let progress: Double
    var id: Int { step.rawValue }
}

struct LadderResult: Equatable {
    let rungs: [LadderRung]
    /// The first rung not yet done; nil when every rung is.
    let current: LadderStep?
    /// Months of essentials the cash + liquid holdings would cover.
    let emergencyMonths: Double
    /// Rupiah still missing to reach the emergency target (0 when reached).
    let emergencyGap: Double
    let emergencyTarget: Double
    let inputs: LadderInputs

    var doneCount: Int { rungs.filter(\.done).count }
    func rung(_ s: LadderStep) -> LadderRung { rungs[s.rawValue - 1] }
}

enum FinancialLadder {
    /// Fahmi's call: three months of essentials. Rural incomes swing with the
    /// harvest and the season, but six months is out of reach for most users
    /// and a target nobody reaches teaches nothing.
    static let emergencyMonthsTarget = 3.0
    /// Debt at or above this yearly rate beats any return a beginner can count
    /// on, so it is paid off before investing. KUR (~6%) stays below it;
    /// paylater, pinjol and credit cards sit far above it.
    static let costlyRate = 10.0
    /// Investing at least this share of income each month counts as regular.
    static let investShareTarget = 0.10

    static func evaluate(_ i: LadderInputs) -> LadderResult {
        // 1 — spending within income.
        let spendingDone = i.monthlyIncome > 0 && i.monthlyConsumption <= i.monthlyIncome
        let spendingProgress = i.monthlyIncome <= 0 ? 0
            : (i.monthlyConsumption <= 0 ? 1 : min(i.monthlyIncome / i.monthlyConsumption, 1))

        // 2 — no costly debt.
        let debtDone = i.costlyDebt == nil

        // 3 — emergency fund. Essentials are the basis; a user who logs only a
        // little gets the larger of essentials and half their consumption.
        let basis = max(i.monthlyEssentials, i.monthlyConsumption * 0.5)
        let buffer = max(0, i.cash) + max(0, i.liquidHoldings)
        let target = basis * emergencyMonthsTarget
        let months = basis > 0 ? buffer / basis : 0
        let emergencyDone = basis > 0 && months >= emergencyMonthsTarget

        // 4 — investing regularly.
        let investTarget = i.monthlyIncome * investShareTarget
        let investingDone = i.investedMonthly > 0
            && (i.investedMonthly >= investTarget || i.portfolioValue + i.pensionValue > 0)
        let investingProgress = investingDone ? 1
            : (investTarget > 0 ? min(i.investedMonthly / investTarget, 1) : 0)

        // 5 — retirement and goals: either a pension fund or a goal being saved for.
        let hasPension = i.pensionValue > 0, hasGoal = i.activeGoals > 0
        let futureDone = hasPension || hasGoal

        let rungs = [
            LadderRung(step: .spending,  done: spendingDone,  progress: spendingProgress),
            LadderRung(step: .debt,      done: debtDone,      progress: debtDone ? 1 : 0),
            LadderRung(step: .emergency, done: emergencyDone,
                       progress: min(months / emergencyMonthsTarget, 1)),
            LadderRung(step: .investing, done: investingDone, progress: investingProgress),
            LadderRung(step: .future,    done: futureDone,    progress: futureDone ? 1 : 0),
        ]
        return LadderResult(rungs: rungs,
                            current: rungs.first(where: { !$0.done })?.step,
                            emergencyMonths: months,
                            emergencyGap: max(0, target - buffer),
                            emergencyTarget: target,
                            inputs: i)
    }
}

// MARK: - Inputs from the user's records

extension LadderInputs {
    /// Reads the last three months (fewer when the history is shorter).
    @MainActor
    static func gather(cards: [BankCard], debts: [DebtRecord], holdings: [InvestmentHolding],
                       goals: [SavingsGoal], salaries: [SalarySchedule], currency: String,
                       now: Date = .now) -> LadderInputs {
        let cm = CurrencyManager.shared
        func conv(_ v: Double, _ from: String) -> Double {
            cm.convert(v, from: from.isEmpty ? currency : from, to: currency)
        }
        let windowStart = Calendar.current.date(byAdding: .day, value: -90, to: now) ?? now
        let txs = cards.flatMap(\.transactions)
            .filter { $0.date >= windowStart && $0.date <= now && $0.txSubtype == .normal }
        let first = txs.map(\.date).min() ?? now
        let months = min(max(now.timeIntervalSince(first) / (30 * 86_400), 1), 3)

        func monthly(_ keep: (TxRecord) -> Bool) -> Double {
            txs.filter(keep).reduce(0.0) { $0 + conv(abs($1.amount), $1.currency) } / months
        }
        let daily = Set(SmartBudgetManager.dailyCategories)
        let living = daily.union(SmartBudgetManager.lifestyleCategories)

        var i = LadderInputs()
        let salary = salaries.filter(\.isActive).reduce(0.0) { $0 + conv($1.amount, $1.currency) }
        i.monthlyIncome = salary > 0 ? salary : monthly { $0.amount > 0 }
        i.monthlyConsumption = monthly { $0.amount < 0 && living.contains($0.category) }
        i.monthlyEssentials = monthly { $0.amount < 0 && daily.contains($0.category) }
        i.investedMonthly = monthly { $0.amount < 0 && $0.category == .investment }

        i.cash = cards.filter { !$0.isCreditCard }
            .reduce(0.0) { $0 + conv($1.computedBalance(), $1.currency) }

        var worst: CostlyDebt?
        for d in debts where d.isActive && !d.manuallyClosed && d.currentBalance > 0
            && d.annualInterestRate >= FinancialLadder.costlyRate {
            if worst == nil || d.annualInterestRate > worst!.annualRate {
                worst = CostlyDebt(name: d.name, annualRate: d.annualInterestRate,
                                   balance: conv(d.currentBalance, d.currency))
            }
        }
        // A credit card balance carried over is costly whatever its rate field
        // says; DiPo doesn't know the rate, so it reads 0 ("rate unknown").
        let cardOwed = cards.reduce(0.0) { $0 + conv($1.owedBalance(), $1.currency) }
        if worst == nil, cardOwed > 0 {
            worst = CostlyDebt(name: loc("ladder.credit_card"), annualRate: 0, balance: cardOwed)
        }
        i.costlyDebt = worst

        for h in holdings {
            let v = conv(h.stats().marketValue, h.currency)
            switch h.type {
            case .pension:        i.pensionValue += v
            case .deposit, .gold: i.liquidHoldings += v; i.portfolioValue += v
            default:              i.portfolioValue += v
            }
        }
        i.activeGoals = goals.filter { !$0.isCompleted }.count
        return i
    }
}
