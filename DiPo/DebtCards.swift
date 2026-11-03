import UserNotifications
import SwiftUI
import SwiftData

// Pieces of the Debts screen: the full list, the owed-back plan and Smart
// Budget's advice (each opened from its own row), the payoff order, the
// payoff celebration and the empty state. The page's rows and its pay-first
// box are in DebtPage.swift.

// MARK: - All Debts (full-list page)
//
// Reached from the "See all" row when there are more than a few debts. The
// rows are self-contained (each opens its own actions), so this page just
// lists them all in the chosen payoff order.
struct AllDebtsView: View {
    let order: [DebtRecord]
    /// Debts with a payment recorded this month, for when each is due.
    let paid: Set<String>
    let vm: DebtViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(order.enumerated()), id: \.element.id) { i, debt in
                            if i > 0 { DebtHairline() }
                            DebtRow(debt: debt, due: DebtDue.of(debt, paid: paid), vm: vm)
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 16)
                    .containerRelativeFrame(.horizontal)
                }
            }
            .navigationTitle(loc("debt.your_debts"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .doneToolbar { dismiss() }
        }
    }
}

// MARK: - Salary Setup CTA (shared empty-state for income-based features)

/// Empty-state card shown by Smart Budget and Debt when no salary/income is
/// set for the current month — those features compute everything as a ratio of
/// income, so they're inert without it. Gives the user a clear one-tap path to
/// set up their salary rather than showing zeros or a silent blank.
struct SalarySetupCTA: View {
    let message: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(AppTheme.accent.opacity(0.12)).frame(width: 56, height: 56)
                Image(systemName: "banknote.fill")
                    .font(.system(.title2))
                    .foregroundStyle(AppTheme.accent)
            }
            VStack(spacing: 6) {
                Text(loc("salary.cta.title"))
                    .font(.system(.callout, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(message)
                    .font(.system(.footnote))
                    .foregroundStyle(AppTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }
            Button {
                HapticManager.shared.tap()
                action()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill").font(.system(.subheadline))
                    Text(loc("salary.cta.button")).font(.system(.subheadline, weight: .bold))
                }
                .foregroundStyle(AppTheme.onVividFill)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(AppTheme.accentFill, in: RoundedRectangle(cornerRadius: AppRadius.md))
            }
            .buttonStyle(ScaleButtonStyle())
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.lg).stroke(AppTheme.accent.opacity(0.2), lineWidth: 1))
    }
}

// MARK: - When the money owed to you comes back

/// What the money others owe would clear, and the month before and after.
/// Opened from its row on the Debts page. The verdict on the page stays
/// today's (see OwedBackPlan).
struct OwedBackBlock: View {
    let plan: OwedBackPlan

    private var currency: String { CurrencyManager.shared.preferredCurrency }
    private func money(_ v: Double) -> String { CurrencyManager.shared.formatted(v, currency: currency) }

    private func tint(_ reading: DebtAffordability) -> Color {
        switch reading.verdict {
        case .heavy?: return AppTheme.red
        case .tight?: return AppTheme.orange
        default:      return AppTheme.accent
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(.caption, weight: .bold))
                    .foregroundStyle(AppTheme.accent)
                    .frame(width: 26, height: 26)
                    .background(AppTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: AppRadius.sm))
                Text(String(format: loc("debt.owed_back.title"), money(plan.owedBack)))
                    .font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 0) {
                ForEach(Array(plan.payoffs.enumerated()), id: \.offset) { n, payoff in
                    if n > 0 { Divider() }
                    payoffRow(payoff)
                }
                if plan.leftOver >= 0.5 {
                    Divider()
                    row(loc("debt.owed_back.left_over"), loc("debt.owed_back.buffer"), money(plan.leftOver), chip: nil)
                }
            }

            VStack(spacing: 6) {
                change(loc("debt.monthly_payments_label"),
                       money(plan.before.monthlyPayments), money(plan.after.monthlyPayments), AppTheme.textPrimary)
                if let was = plan.before.verdictLabel, let will = plan.after.verdictLabel {
                    change(loc("debt.owed_back.verdict"), was, will, tint(plan.after))
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(AppTheme.cardMid.opacity(0.5), in: RoundedRectangle(cornerRadius: AppRadius.sm))

            Text(plan.note(currency: currency))
                .font(.system(.caption))
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .overlay(RoundedRectangle(cornerRadius: AppRadius.md).stroke(AppTheme.cardMid, lineWidth: 1))
    }

    private func payoffRow(_ payoff: OwedBackPlan.Payoff) -> some View {
        let detail: String
        switch payoff.debt.kind {
        case .card:              detail = loc("debt.owed_back.carried")
        case .loan(let rate):    detail = String(format: loc("debt.owed_back.rate"), DebtFirstAdvice.rate(rate))
        }
        let chip = payoff.cleared
            ? (loc("debt.owed_back.cleared"), AppTheme.accent)
            : (String(format: loc("debt.owed_back.of"), money(payoff.debt.balance)), AppTheme.textSecondary)
        return row(payoff.debt.name, detail, money(payoff.paid), chip: chip)
    }

    private func row(_ title: String, _ detail: String, _ amount: String, chip: (String, Color)?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.footnote))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                Text(detail)
                    .font(.system(.caption))
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 3) {
                Text(amount)
                    .font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                if let chip {
                    Text(chip.0)
                        .font(.system(.caption2, weight: .bold))
                        .foregroundStyle(chip.1)
                        .lineLimit(1)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(chip.1.opacity(0.12), in: Capsule())
                }
            }
            .fixedSize()
        }
        .padding(.vertical, 8)
    }

    private func change(_ label: String, _ was: String, _ will: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(.caption))
                .foregroundStyle(AppTheme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(was)
                .font(.system(.caption))
                .strikethrough()
                .foregroundStyle(AppTheme.textSecondary)
                .lineLimit(1)
            Image(systemName: "arrow.right")
                .font(.system(.caption2, weight: .semibold))
                .foregroundStyle(AppTheme.textSecondary)
            Text(will)
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .minimumScaleFactor(0.85)
    }
}

// MARK: - Smart Budget: debt before saving

/// What Smart Budget advises doing with its savings & debt share while
/// something is owed. It replaces "Where your salary goes", a four-way split
/// of the salary that is Smart Budget's own screen, and a pay-period warning
/// that is Statistics'. Here Smart Budget answers one thing: the minimums come
/// out of its share — does the rest go to a dear debt, or to saving?
struct DebtFirstCard: View {
    let advice: DebtFirstAdvice

    private var currency: String { CurrencyManager.shared.preferredCurrency }
    private func money(_ v: Double) -> String { CurrencyManager.shared.formatted(v, currency: currency) }

    private var extraLabel: String {
        switch advice.target {
        case .card:                    return loc("debt.first.row_extra_card")
        case .debt(let name, _, _, _): return String(format: loc("debt.first.row_extra_debt"), name)
        case nil:                      return loc("debt.first.row_save")
        }
    }

    private var minimumTint: Color { AppTheme.red.opacity(0.8) }
    /// The rest of the share: towards the dear debt, or saved.
    private var extraTint: Color { advice.target == nil ? AppTheme.blue.opacity(0.8) : AppTheme.red.opacity(0.4) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(loc("debt.first.header").uppercased(with: LanguageManager.shared.currentLocale))
                    .font(.system(.caption2, weight: .heavy))
                    .tracking(1)
                    .foregroundStyle(AppTheme.textSecondary)
                Text(advice.title())
                    .font(.system(.body, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let line = advice.shareLine(currency: currency) {
                Text(line)
                    .font(.system(.caption))
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if advice.closeTheGapFirst {
                // No bar: the share it would split is not there yet.
                VStack(spacing: 6) {
                    row(minimumTint, loc("debt.first.row_min"), money(advice.minimums))
                    row(extraTint, extraLabel, loc("debt.first.row_after_gap"), muted: true)
                    if advice.target != nil {
                        row(AppTheme.blue.opacity(0.4), loc("debt.first.row_save"),
                            loc("debt.first.row_save_later"), muted: true)
                    }
                }
            } else if !advice.noRoom {
                split
                VStack(spacing: 6) {
                    row(minimumTint, loc("debt.first.row_min"), money(advice.minimums))
                    row(extraTint, extraLabel, money(advice.extra))
                    if advice.target != nil {
                        row(AppTheme.blue.opacity(0.4), loc("debt.first.row_save"),
                            loc("debt.first.row_save_later"), muted: true)
                    }
                }
            }

            Text(advice.body(currency: currency))
                .font(.system(.caption))
                .foregroundStyle(AppTheme.textPrimary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppTheme.cardMid.opacity(0.5), in: RoundedRectangle(cornerRadius: AppRadius.md))
        }
        .padding(16)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.xl))
    }

    /// The share, split into the minimums and the rest.
    private var split: some View {
        GeometryReader { g in
            // The minimums and what can really go on top of them.
            let total = max(advice.minimums + advice.extra, 1)
            let minShare = CGFloat(min(advice.minimums / total, 1))
            HStack(spacing: 2) {
                if minShare > 0 {
                    RoundedRectangle(cornerRadius: 4).fill(minimumTint)
                        .frame(width: max(g.size.width * minShare - 1, 0), height: 10)
                }
                RoundedRectangle(cornerRadius: 4).fill(extraTint)
                    .frame(height: 10)
            }
        }
        .frame(height: 10)
        .accessibilityHidden(true)
    }

    private func row(_ tint: Color, _ label: String, _ value: String, muted: Bool = false) -> some View {
        // Label wraps, figure never does.
        HStack(spacing: 8) {
            Circle().fill(tint).frame(width: 7, height: 7)
            Text(label)
                .font(.system(.caption))
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(.caption, weight: muted ? .medium : .semibold))
                .foregroundStyle(muted ? AppTheme.textSecondary : AppTheme.textPrimary)
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Debt Payoff Celebration
//
// Reaching a savings goal already gets confetti. Clearing a debt used to get a
// haptic buzz and silence — even though it is the harder of the two, and the
// one people spend years on. This gives it the same vocabulary as
// `GoalCelebration` (scrim, confetti, staggered springs, cascade haptic) so the
// app has one way of saying "well done" rather than two.
//
// The copy stays concrete: how long it took, and how much monthly cash just
// came back. A bare "Congratulations!" is a greeting card; the numbers are the
// reason to feel good.
struct DebtPayoffCelebration: View {
    let summary: ActionFeedbackCenter.DebtPayoffSummary
    let onDismiss: () -> Void

    @State private var scale: CGFloat = 0.5
    @State private var opacity: Double = 0
    @State private var ring: CGFloat = 0.6
    @State private var ringFade: Double = 0.55

    var body: some View {
        ZStack {
            Color.black.opacity(0.78).ignoresSafeArea()

            ConfettiView()
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 22) {
                ZStack {
                    // A ring that expands outward and fades — the visual echo
                    // of a weight being lifted.
                    Circle()
                        .stroke(AppTheme.accent.opacity(ringFade), lineWidth: 2)
                        .frame(width: 118, height: 118)
                        .scaleEffect(ring)
                    Circle()
                        .fill(AppTheme.accent.opacity(0.15))
                        .frame(width: 104, height: 104)
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 56, weight: .semibold))
                        .foregroundStyle(AppTheme.accent)
                }
                .scaleEffect(scale)

                VStack(spacing: 9) {
                    Text(loc("debt.celebrate.title"))
                        .font(.system(.title, weight: .bold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(summary.name)
                        .font(.system(.body, weight: .semibold))
                        .foregroundStyle(AppTheme.accent)
                        .multilineTextAlignment(.center)
                    Text(String(format: loc("debt.celebrate.paid"),
                                CurrencyManager.shared.formatted(summary.total, currency: summary.currency)))
                        .font(.system(.subheadline))
                        .foregroundStyle(AppTheme.textSecondary)
                        .multilineTextAlignment(.center)

                    // Two facts worth carrying away: the effort behind it, and
                    // the money it hands back every month from here on.
                    VStack(spacing: 5) {
                        Text(summary.monthsTaken >= 1
                             ? String(format: loc("debt.celebrate.took"), summary.monthsTaken)
                             : loc("debt.celebrate.took_one"))
                        if summary.monthlyFreed > 0.5 {
                            Text(String(format: loc("debt.celebrate.freed"),
                                        CurrencyManager.shared.formatted(summary.monthlyFreed, currency: summary.currency)))
                                .foregroundStyle(AppTheme.accent.opacity(0.9))
                        }
                    }
                    .font(.system(.caption, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)
                }
                .padding(.horizontal, 28)
                .scaleEffect(scale)
                .opacity(opacity)

                Button {
                    HapticManager.shared.success()
                    onDismiss()
                } label: {
                    Text(loc("debt.celebrate.cta"))
                        .font(.system(.callout, weight: .bold))
                        .foregroundStyle(AppTheme.bg)
                        .padding(.horizontal, 44).padding(.vertical, 15)
                        .background(AppTheme.accentFill, in: Capsule())
                }
                .buttonStyle(ScaleButtonStyle())
                .scaleEffect(scale)
                .opacity(opacity)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) { scale = 1.1 }
            withAnimation(.easeOut(duration: 1.1)) { ring = 1.55; ringFade = 0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { scale = 1.0; opacity = 1 }
            }
            for i in 0..<5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.08) {
                    HapticManager.shared.rigidImpact()
                }
            }
        }
    }
}

// MARK: - Payoff order

/// Which debt goes first: highest interest, or smallest balance. It sets the
/// pay-first box and the order of the rows under it.
struct DebtStrategyPicker: View {
    /// 0 = highest interest first, 1 = smallest balance first.
    @Binding var strategy: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Plain names. "Avalanche" and "Snowball" are terms from personal-
            // finance blogs, in English, on a screen most people read in Indonesian.
            HStack(spacing: 2) {
                ForEach([0, 1], id: \.self) { i in
                    let on = strategy == i
                    Button {
                        HapticManager.shared.tap()
                        withAnimation(.spring(response: 0.3)) { strategy = i }
                    } label: {
                        // The choice in ink, as on Statistics' flow toggle:
                        // the page's ground on this track hid it in the light theme.
                        Text(loc(i == 0 ? "debt.strategy_interest" : "debt.strategy_small"))
                            .font(.system(.footnote, weight: .semibold))
                            .foregroundStyle(on ? AppTheme.cardDark : AppTheme.textSecondary)
                            .lineLimit(1).minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                            .background(on ? AppTheme.textPrimary : Color.clear, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(3)
            .background(AppTheme.cardMid, in: Capsule())

            Text(loc(strategy == 0 ? "debt.avalanche_desc" : "debt.snowball_desc"))
                .font(.system(.caption))
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Empty State

struct DebtEmptyState: View {
    @Bindable var vm: DebtViewModel
    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle().fill(AppTheme.accent.opacity(0.14)).frame(width: 120, height: 120)
                Circle().fill(AppTheme.accentFill).frame(width: 76, height: 76)
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(.title, weight: .semibold))
                    .foregroundStyle(AppTheme.onVividFill)
            }
            VStack(spacing: 8) {
                Text(loc("debt.no_debts"))
                    .font(.system(.title3, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(loc("debt.empty_desc"))
                    .font(.system(.subheadline))
                    .foregroundStyle(AppTheme.textSecondary)
                    .multilineTextAlignment(.center).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button { HapticManager.shared.tap(); vm.resetForm(); vm.showAddSheet = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill").font(.system(.body))
                    Text(loc("debt.add")).font(.system(.callout, weight: .bold))
                }
                .foregroundStyle(AppTheme.onVividFill)
                .frame(maxWidth: .infinity).padding(.vertical, 16)
                .background(AppTheme.accentFill, in: RoundedRectangle(cornerRadius: AppRadius.lg))
            }
            .buttonStyle(ScaleButtonStyle())
        }
        .padding(.horizontal, 10)
    }
}
