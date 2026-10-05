import SwiftUI
import SwiftData

// MARK: - Copy
//
// One line per rung in the user's own figures. Kept out of the views so the
// wording can be tested against real numbers.

enum LadderCopy {
    static func detail(_ s: LadderStep, _ r: LadderResult, currency: String) -> String {
        let i = r.inputs
        let money = { (v: Double) in CurrencyManager.shared.formatted(v.rounded(), currency: currency) }
        switch s {
        case .spending:
            if i.monthlyIncome <= 0 { return loc("ladder.spending.no_income") }
            return r.rung(.spending).done
                ? String(format: loc("ladder.spending.ok"), money(i.monthlyConsumption), money(i.monthlyIncome))
                : String(format: loc("ladder.spending.over"), money(i.monthlyConsumption - i.monthlyIncome))
        case .debt:
            guard let d = i.costlyDebt else { return loc("ladder.debt.ok") }
            return d.annualRate > 0
                ? String(format: loc("ladder.debt.rate"), d.name, Int(d.annualRate.rounded()), money(d.balance))
                : String(format: loc("ladder.debt.card"), d.name, money(d.balance))
        case .emergency:
            if r.emergencyTarget <= 0 { return loc("ladder.emergency.no_data") }
            return r.rung(.emergency).done
                ? String(format: loc("ladder.emergency.ok"), months(r.emergencyMonths))
                : String(format: loc("ladder.emergency.short"), months(r.emergencyMonths), money(r.emergencyGap))
        case .investing:
            let share = FinancialLadder.investShare(for: i)
            let aim = money(i.monthlyIncome * share)
            let pct = Int((share * 100).rounded())
            if r.rung(.investing).done { return String(format: loc("ladder.investing.ok"), money(i.investedMonthly)) }
            return i.investedMonthly > 0
                ? String(format: loc("ladder.investing.some"), money(i.investedMonthly), aim, pct)
                : String(format: loc("ladder.investing.none"), aim, pct)
        case .future:
            switch (i.pensionValue > 0, i.activeGoals > 0) {
            case (true, true):  return String(format: loc("ladder.future.both"), money(i.pensionValue), i.activeGoals)
            case (true, false): return String(format: loc("ladder.future.pension"), money(i.pensionValue))
            case (false, true): return String(format: loc("ladder.future.goals"), i.activeGoals)
            case (false, false): return loc("ladder.future.none")
            }
        }
    }

    /// "1,8" / "1.8" — one decimal, in the app language's own style.
    static func months(_ m: Double) -> String {
        let f = NumberFormatter()
        f.locale = LanguageManager.shared.currentLocale
        f.minimumFractionDigits = 1
        f.maximumFractionDigits = 1
        return f.string(from: NSNumber(value: (m * 10).rounded(.down) / 10)) ?? String(format: "%.1f", m)
    }

    static func cardSubtitle(_ r: LadderResult) -> String {
        guard let s = r.current else { return loc("ladder.card_done") }
        return String(format: loc("ladder.card_step"), s.rawValue, LadderStep.allCases.count, s.title)
    }
}

// MARK: - Plan tab card

/// The ladder at a glance: which step the user is on and the one figure that
/// matters for it. Opens the full ladder.
struct FinancialLadderCard: View {
    let result: LadderResult
    let currency: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Image(systemName: (result.current ?? .future).icon)
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
                    .frame(width: 40, height: 40)
                    .background(AppTheme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: AppRadius.sm))
                VStack(alignment: .leading, spacing: 3) {
                    Text(loc("ladder.title"))
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(LadderCopy.cardSubtitle(result))
                        .font(.system(.caption))
                        .foregroundStyle(AppTheme.textSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            LadderSegments(result: result)
            Text(LadderCopy.detail(result.current ?? .future, result, currency: currency))
                .font(.system(.footnote))
                .foregroundStyle(AppTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Five segments, one per rung: filled when done, part-filled by progress.
private struct LadderSegments: View {
    let result: LadderResult
    var body: some View {
        HStack(spacing: 4) {
            ForEach(result.rungs) { r in
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(AppTheme.cardMid)
                        Capsule().fill(AppTheme.accent)
                            .frame(width: g.size.width * (r.done ? 1 : max(0, min(r.progress, 1))))
                    }
                }
                .frame(height: 6)
            }
        }
    }
}

// MARK: - Full ladder

struct FinancialLadderView: View {
    @Query private var cards: [BankCard]
    @Query private var debts: [DebtRecord]
    @Query private var holdings: [InvestmentHolding]
    @Query private var goals: [SavingsGoal]
    @Query private var salaries: [SalarySchedule]
    @State private var openWhy: LadderStep?
    /// Read from the whole history, so refreshed on save, not per render —
    /// opening a "Why?" redraws the screen.
    @State private var cached: LadderResult?

    private var currency: String { CurrencyManager.shared.preferredCurrency }

    private func computeResult() -> LadderResult {
        FinancialLadder.evaluate(.gather(cards: cards, debts: debts, holdings: holdings,
                                         goals: goals, salaries: salaries, currency: currency))
    }

    var body: some View {
        let r = cached ?? computeResult()
        ZStack {
            AppTheme.bg.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(loc("ladder.title"))
                            .font(.system(.title, weight: .bold))
                            .foregroundStyle(AppTheme.textPrimary)
                        Text(loc("ladder.intro"))
                            .font(.system(.footnote))
                            .foregroundStyle(AppTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(spacing: 0) {
                        ForEach(r.rungs) { rung in
                            rungRow(rung, r)
                            if rung.step != .future {
                                Rectangle().fill(AppTheme.cardMid.opacity(0.7)).frame(height: 1)
                                    .padding(.leading, 62)
                            }
                        }
                    }
                    .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))

                    Text(loc("ladder.disclaimer"))
                        .font(.system(.caption2))
                        .foregroundStyle(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 100)
                }
                .padding(.horizontal, 22)
                .padding(.top, 12)
                .containerRelativeFrame(.horizontal)
            }
        }
        // Always pushed from Plan: the bar is there for the back button only.
        .featureBar(pushed: true)
        .onStoreChange { cached = computeResult() }
    }

    private func rungRow(_ rung: LadderRung, _ r: LadderResult) -> some View {
        let isCurrent = r.current == rung.step
        let tint = rung.done ? AppTheme.accent : (isCurrent ? AppTheme.textPrimary : AppTheme.textSecondary)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle().fill(rung.done ? AppTheme.accent.opacity(0.16) : AppTheme.cardMid)
                    if rung.done {
                        Image(systemName: "checkmark").font(.system(.caption, weight: .bold))
                            .foregroundStyle(AppTheme.accent)
                    } else {
                        Text("\(rung.step.rawValue)").font(.system(.caption, weight: .bold))
                            .foregroundStyle(tint)
                    }
                }
                .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(rung.step.title)
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundStyle(AppTheme.textPrimary)
                        if isCurrent {
                            Text(loc("ladder.now"))
                                .font(.system(.caption2, weight: .bold))
                                .foregroundStyle(AppTheme.accent)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(AppTheme.accent.opacity(0.12), in: Capsule())
                        }
                    }
                    Text(LadderCopy.detail(rung.step, r, currency: currency))
                        .font(.system(.caption))
                        .foregroundStyle(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if isCurrent && rung.progress > 0 && rung.progress < 1 {
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(AppTheme.cardMid)
                                Capsule().fill(AppTheme.accent).frame(width: g.size.width * rung.progress)
                            }
                        }
                        .frame(height: 6)
                        .padding(.top, 2)
                    }
                    Button {
                        HapticManager.shared.tap()
                        withAnimation(.easeInOut(duration: 0.2)) {
                            openWhy = openWhy == rung.step ? nil : rung.step
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(loc("ladder.why_label"))
                            Image(systemName: openWhy == rung.step ? "chevron.up" : "chevron.down")
                                .imageScale(.small)
                        }
                        .font(.system(.caption, weight: .semibold))
                        .foregroundStyle(AppTheme.accent)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                    if openWhy == rung.step {
                        Text(rung.step.why)
                            .font(.system(.caption))
                            .foregroundStyle(AppTheme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .transition(.opacity)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(16)
    }
}
