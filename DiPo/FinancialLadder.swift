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
        /// The costly part: for a card, what is carried over from earlier bills.
        var balance: Double
        /// For a card, everything owed on it — the figure the Debts screen
        /// shows — so the two screens can be read side by side. Zero when it
        /// is the same as `balance`.
        var owedInTotal: Double = 0
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
    /// Someone who already holds a portfolio or pension only needs to keep
    /// topping it up — half the share, but not a token Rp 50 rb.
    static let investShareWithPortfolio = 0.05

    /// The share of income this person should aim to invest.
    static func investShare(for i: LadderInputs) -> Double {
        i.portfolioValue + i.pensionValue > 0 ? investShareWithPortfolio : investShareTarget
    }

    /// The middle month of the last complete months. One big month — a
    /// wedding, a motorbike, the dentist — moved a three-month AVERAGE enough
    /// to call every month a deficit; the median shrugs it off.
    static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted(), m = s.count / 2
        return s.count % 2 == 0 ? (s[m - 1] + s[m]) / 2 : s[m]
    }

    /// Totals for each of the last `count` COMPLETE calendar months, oldest
    /// first, leaving out months before the user started logging (a month
    /// that began more than a week before their first record would read as
    /// a near-empty month and drag the median down).
    static func completeMonthTotals(_ items: [(date: Date, amount: Double)], count: Int,
                                    firstActivity: Date, now: Date, cal: Calendar) -> [Double] {
        guard let thisMonth = cal.date(from: cal.dateComponents([.year, .month], from: now)) else { return [] }
        var out: [Double] = []
        for back in stride(from: count, through: 1, by: -1) {
            guard let start = cal.date(byAdding: .month, value: -back, to: thisMonth),
                  let end = cal.date(byAdding: .month, value: 1, to: start) else { continue }
            if firstActivity > start.addingTimeInterval(7 * 86_400) { continue }
            out.append(items.filter { $0.date >= start && $0.date < end }.reduce(0) { $0 + $1.amount })
        }
        return out
    }

    /// What is owed on a credit card from before the current and last
    /// statement. Recent charges are normal card use, paid off when the bill
    /// comes; only an older balance is being carried — and charged interest.
    static func carriedOver(owed: Double, recentCharges: Double) -> Double {
        max(owed - recentCharges, 0)
    }

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

        // 4 — investing regularly: a real share of income, not a token amount.
        let investTarget = i.monthlyIncome * investShare(for: i)
        let investingDone = i.investedMonthly > 0 && investTarget > 0
            && i.investedMonthly >= investTarget
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
                       installments: [CardInstallment] = [], now: Date = .now) -> LadderInputs {
        let cm = CurrencyManager.shared
        func conv(_ v: Double, _ from: String) -> Double {
            cm.convert(v, from: from.isEmpty ? currency : from, to: currency)
        }
        let cal = Calendar.current
        let thisMonth = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now
        let windowStart = cal.date(byAdding: .month, value: -3, to: thisMonth) ?? now
        let allTx = cards.flatMap(\.transactions)
        // Normal transactions only; a purchase the user marked as a one-off
        // isn't what a month usually costs.
        let txs = allTx
            .filter { $0.date >= windowStart && $0.date <= now && $0.txSubtype == .normal }
            .filter { !($0.amount < 0 && $0.oneOffOverride == true) }
        let firstActivity = allTx.map(\.date).min() ?? now

        let daily = Set(SmartBudgetManager.dailyCategories)
        let living = daily.union(SmartBudgetManager.lifestyleCategories)

        /// Median of the last three complete months; until there is one, the
        /// month so far stretched to a full month.
        func typicalMonth(_ keep: (TxRecord) -> Bool) -> Double {
            let items = txs.filter(keep).map { (date: $0.date, amount: conv(abs($0.amount), $0.currency)) }
            let months = FinancialLadder.completeMonthTotals(items, count: 3, firstActivity: firstActivity,
                                                            now: now, cal: cal)
            if !months.isEmpty { return FinancialLadder.median(months) }
            let soFar = items.filter { $0.date >= thisMonth }.reduce(0) { $0 + $1.amount }
            let days = max(now.timeIntervalSince(max(thisMonth, firstActivity)) / 86_400, 7)
            return soFar / days * 30
        }
        /// Investing is lumpy by nature (a gold bar one month, nothing the
        /// next), so it is averaged over the window rather than taken as a median.
        func averageMonth(_ keep: (TxRecord) -> Bool) -> Double {
            let span = now.timeIntervalSince(max(windowStart, firstActivity)) / (30 * 86_400)
            return txs.filter(keep).reduce(0.0) { $0 + conv(abs($1.amount), $1.currency) } / min(max(span, 1), 4)
        }

        var i = LadderInputs()
        let salary = salaries.filter(\.isActive).reduce(0.0) { $0 + conv($1.amount, $1.currency) }
        // Side income that keeps coming — a weekend stall, a monthly transfer
        // from family — pays for the month as surely as the salary does.
        // Leaving it out told a user earning Rp 11 jt a month that they spent
        // Rp 2 jt more than they earned. Only COMPLETE months, and their
        // median, so a bonus, a THR or one big sale doesn't count; nor do
        // selling an investment or taking a loan, which aren't earning.
        let sideItems = txs
            .filter { $0.amount > 0 && ![.salary, .bonus, .investment, .debtPayment].contains($0.category) }
            .map { (date: $0.date, amount: conv($0.amount, $0.currency)) }
        let sideMonths = FinancialLadder.completeMonthTotals(sideItems, count: 3, firstActivity: firstActivity,
                                                             now: now, cal: cal)
        let sideIncome = sideMonths.isEmpty ? 0 : FinancialLadder.median(sideMonths)
        i.monthlyIncome = salary > 0 ? salary + sideIncome : typicalMonth { $0.amount > 0 }
        i.monthlyConsumption = typicalMonth { $0.amount < 0 && living.contains($0.category) }
        i.monthlyEssentials = typicalMonth { $0.amount < 0 && daily.contains($0.category) }
        i.investedMonthly = averageMonth { $0.amount < 0 && $0.category == .investment }

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
        // A credit card balance CARRIED OVER is costly whatever its rate; one
        // paid in full each month costs nothing. DiPo can't see the statement,
        // so charges from this month and last count as the open bill and only
        // what is older counts as carried. Rate unknown, so it reads 0.
        //
        // The same rule, from the same function, as the Debts screen's
        // monthly payment, and the total beside it is the Debts screen's
        // total. The ladder used to say "Rp 8.000.000 still owed" while
        // Debts said Rp 8.500.000: both right, but nothing said that the
        // other Rp 500.000 was this month's shopping, not yet due.
        let cardCarried = ObligationLoad.cardCarried(cards: cards, currency: currency, now: now)
        if worst == nil, cardCarried >= 0.5 {
            let cardTotal = cards.filter(\.isCreditCard).reduce(0.0) {
                $0 + cm.convert($1.totalOwed(installments), from: $1.resolvedCurrency, to: currency)
            }
            worst = CostlyDebt(name: loc("ladder.credit_card"), annualRate: 0, balance: cardCarried,
                               owedInTotal: cardTotal > cardCarried + 0.5 ? cardTotal : 0)
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
