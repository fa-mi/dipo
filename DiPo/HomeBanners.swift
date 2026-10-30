import SwiftUI
import SwiftData

// Moved out of HomeView.swift, unchanged. The setup steps, banners and attention rows Home stacks above the ledger.

// MARK: - No Card State

struct NoCardState: View {
    @Binding var showAddCard: Bool
    @Binding var showAddSalary: Bool

    // Progress: 0 of 3 steps done when no card
    private let steps: [(String, String, String)] = [
        ("creditcard.fill",   "Add a card",    "Visa or Mastercard"),
        ("banknote.fill",     "Set up salary", "So we know your income"),
        ("plus.circle.fill",  "Add expenses",  "Track your spending")
    ]

    var body: some View {
        VStack(spacing: 24) {
            // Animated mascot
            ZStack {
                ForEach(0..<3) { i in
                    Circle()
                        .stroke(AppTheme.accent.opacity(0.10 - Double(i) * 0.025), lineWidth: 1.5)
                        .frame(width: CGFloat(110 + i * 40), height: CGFloat(110 + i * 40))
                }
                Circle()
                    .fill(Color.black)
                    .frame(width: 96, height: 96)
                    .shadow(color: AppTheme.accent.opacity(0.45), radius: 20)
                DiPoLogo(size: 96, showBackground: true)
                    .clipShape(Circle())
            }

            VStack(spacing: 6) {
                Text(loc("home.get_started")).font(.system(.title2, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                Text(loc("home.get_started_sub"))
                    .font(.system(.subheadline)).foregroundStyle(AppTheme.textSecondary)
                    .multilineTextAlignment(.center).lineSpacing(3)
            }

            // Progress bar
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(AppTheme.accentTrack).frame(height: 6)
                    RoundedRectangle(cornerRadius: 4).fill(AppTheme.accentFill).frame(width: g.size.width * 0, height: 6)
                }
            }
            .frame(height: 6)
            .padding(.horizontal, 32)

            Text(loc("home.step1")).font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)

            // Tappable step rows
            VStack(spacing: 10) {
                // Step 1 — Add card (always active, tappable)
                Button { HapticManager.shared.tap(); showAddCard = true } label: {
                    TappableSetupStep(number: 1, icon: "creditcard.fill", title: loc("onboarding.add_card"),
                                      subtitle: loc("onboarding.sub_card"), isActive: true, isDone: false)
                }
                .buttonStyle(ScaleButtonStyle())

                // Step 2 — Salary (shown but requires card first — tap shows hint)
                TappableSetupStep(number: 2, icon: "banknote.fill", title: loc("onboarding.add_salary"),
                                  subtitle: loc("onboarding.sub_salary"), isActive: false, isDone: false)

                // Step 3 — Expenses (locked)
                TappableSetupStep(number: 3, icon: "plus.circle.fill", title: loc("onboarding.add_transactions"),
                                  subtitle: loc("onboarding.sub_transactions"), isActive: false, isDone: false)
            }
            .padding(.horizontal, 28)

            Button { HapticManager.shared.success(); showAddCard = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "plus.circle.fill").font(.system(.body))
                    Text(loc("home.add_first_card")).font(.system(.callout, weight: .bold))
                }
                .foregroundStyle(AppTheme.onVividFill)
                .padding(.horizontal, 36).padding(.vertical, 16)
                .background(AppTheme.accentFill, in: Capsule())
            }
            .buttonStyle(ScaleButtonStyle())
        }
        .padding(.horizontal, 8)
    }
}

struct TappableSetupStep: View {
    let number: Int
    let icon: String
    let title: String
    let subtitle: String
    let isActive: Bool
    let isDone: Bool

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(isDone ? AppTheme.accent : isActive ? AppTheme.accent.opacity(0.15) : AppTheme.cardDark)
                    .frame(width: 36, height: 36)
                    .overlay(Circle().stroke(isActive || isDone ? AppTheme.accent.opacity(0.5) : AppTheme.cardMid, lineWidth: 1))
                if isDone {
                    Image(systemName: "checkmark").font(.system(.footnote, weight: .bold)).foregroundStyle(AppTheme.bg)
                } else {
                    Image(systemName: icon).font(.system(.subheadline))
                        .foregroundStyle(isActive ? AppTheme.accent : AppTheme.textSecondary.opacity(0.5))
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(isActive ? AppTheme.textPrimary : AppTheme.textSecondary.opacity(0.5))
                Text(subtitle).font(.system(.caption))
                    .foregroundStyle(AppTheme.textSecondary.opacity(isActive ? 0.8 : 0.4))
            }
            Spacer()
            if isActive {
                ZStack {
                    Circle().fill(AppTheme.accentFill).frame(width: 28, height: 28)
                    Image(systemName: "chevron.right").font(.system(.caption2, weight: .bold)).foregroundStyle(AppTheme.bg)
                }
            } else if isDone {
                Image(systemName: "checkmark.circle.fill").font(.system(.title2)).foregroundStyle(AppTheme.accent)
            } else {
                Circle().fill(AppTheme.cardMid).frame(width: 28, height: 28)
                    .overlay(Image(systemName: "lock.fill").font(.system(.caption2)).imageScale(.small).foregroundStyle(AppTheme.textSecondary.opacity(0.4)))
            }
        }
        .padding(14)
        .background(isActive ? AppTheme.accent.opacity(0.07) : AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.md).stroke(isActive ? AppTheme.accent.opacity(0.25) : Color.clear, lineWidth: 1))
    }
}


// MARK: - Recurring Reminder Banner

struct RecurringReminderBanner: View {
    let pattern: SmartBudgetManager.RecurringPattern
    /// Called after the user hides this detected pattern, so Home can recompute.
    var onDismiss: (() -> Void)? = nil

    private var daysUntil: Int {
        max(Calendar.current.dateComponents([.day], from: Date(), to: pattern.nextExpected).day ?? 0, 0)
    }

    /// A fixed bill/subscription vs a frequent discretionary habit — drives all
    /// the labels, colors, and copy so a warteg run never reads like a CC bill.
    private var isBill: Bool { pattern.kind == .bill }
    /// Bills keep the neutral blue "reminder" look; habits borrow the category
    /// color + icon so they clearly read as "your food/transport spending".
    private var tint: Color { isBill ? AppTheme.blue : pattern.category.color }
    private var iconName: String { isBill ? "arrow.clockwise.circle.fill" : pattern.category.icon }
    private var badgeText: String { isBill ? loc("tx.recurring") : loc("recurring.badge.habit") }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(tint.opacity(0.15)).frame(width: 40, height: 40)
                Image(systemName: iconName)
                    .font(.system(.body)).foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(badgeText)
                        .font(.system(.caption2, weight: .semibold))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(tint.opacity(0.15), in: Capsule())
                    Text(pattern.frequencyLabel)
                        .font(.system(.caption2, weight: .medium))
                        .foregroundStyle(AppTheme.textSecondary)
                        .lineLimit(1)
                    // "Due today" only makes sense for a bill — a habit isn't due.
                    if isBill && daysUntil == 0 {
                        Text(loc("tx.due_today"))
                            .font(.system(.caption2, weight: .semibold))
                            .foregroundStyle(AppTheme.red)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(AppTheme.red.opacity(0.15), in: Capsule())
                    }
                }
                // Merchant name gets the whole line. Appending the cadence here
                // ate the width and truncated BOTH ("makan malam hangry
                // nashville · ti…"), hiding the very thing that explains the
                // flag — so the cadence moved up beside the badge instead.
                Text(pattern.name)
                    .font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1).truncationMode(.tail)
                // Detail — bills get a "due" prediction; habits are framed as an
                // average spend, no due-date pressure.
                let amountStr = CurrencyManager.shared.formatted(pattern.amount, currency: pattern.currency)
                Text(detailText(amountStr))
                    .font(.system(.caption2))
                    .foregroundStyle(AppTheme.textSecondary)
                // One-line explainer so first-time users aren't confused.
                // The evidence behind the claim, stated plainly: how many
                // times, and over what span. Without it a detected pattern is
                // an assertion the user has no way to check.
                Text(String(format: loc("recurring.evidence"),
                            pattern.occurrences, evidenceRange))
                    .font(.system(.caption2))
                    .foregroundStyle(AppTheme.textSecondary.opacity(0.8))

                Text(isBill ? loc("recurring.help.bill") : loc("recurring.help.habit"))
                    .font(.system(.caption2))
                    .foregroundStyle(AppTheme.textSecondary.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            // Dismiss — hides this auto-detected pattern. It's derived from your
            // transactions (not a schedule you can delete), so this is the only
            // way to stop it reappearing.
            if let onDismiss {
                Button {
                    HapticManager.shared.tap()
                    SmartBudgetManager.shared.dismissRecurring(name: pattern.name)
                    withAnimation(.spring(response: 0.4)) { onDismiss() }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(.caption, weight: .bold))
                        .foregroundStyle(AppTheme.textSecondary)
                        .frame(width: 26, height: 26)
                        .background(AppTheme.cardMid, in: Circle())
                }
.accessibilityLabel(loc("a11y.dismiss"))
                .buttonStyle(ScaleButtonStyle())
            }
        }
        .padding(12)
        .background(tint.opacity(0.06), in: RoundedRectangle(cornerRadius: AppRadius.md))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.md).stroke(tint.opacity(0.2), lineWidth: 1))
    }

    /// "14 Aug – 21 Aug" for the sightings this pattern was built from.
    private var evidenceRange: String {
        let df = DateFormatter()
        df.locale = LanguageManager.shared.currentLocale
        df.dateFormat = DateFormatter.dateFormat(fromTemplate: "d MMM", options: 0,
                                                 locale: LanguageManager.shared.currentLocale)
        let first = df.string(from: pattern.firstDate)
        let last  = df.string(from: pattern.lastDate)
        return first == last ? last : "\(first) – \(last)"
    }

    private func detailText(_ amountStr: String) -> String {
        if !isBill {
            // Habit: an average per-visit spend, not a payment due.
            return String(format: loc("recurring.detail_habit"), amountStr)
        }
        return daysUntil == 0
            ? String(format: loc("recurring.detail_today"), amountStr)
            : String(format: loc("recurring.detail"), amountStr, daysUntil)
    }
}

// MARK: - Setup Salary Banner

struct SetupSalaryBanner: View {
    @Binding var showAddSalary: Bool

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(AppTheme.blue.opacity(0.15)).frame(width: 42, height: 42)
                Image(systemName: "banknote").font(.system(.body)).foregroundStyle(AppTheme.blue)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(loc("home.setup_salary"))
                    .font(.system(.subheadline, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                Text(loc("home.setup_salary_sub"))
                    .font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
            }
            Spacer()
            Button {
                HapticManager.shared.tap()
                showAddSalary = true
            } label: {
                Text(loc("home.set_up"))
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(AppTheme.bg)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(AppTheme.blue, in: Capsule())
            }
            .buttonStyle(ScaleButtonStyle())
        }
        .padding(14)
        .background(AppTheme.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: AppRadius.md))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.md).stroke(AppTheme.blue.opacity(0.2), lineWidth: 1))
    }
}


// MARK: - Pinned Goal Banner

struct PinnedGoalBanner: View {
    let goal: SavingsGoal
    var tappable: Bool = false

    // The goal's own figures: its cash and any investments it is kept in.
    private var progress: Double { goal.progress }
    private var remaining: Double { goal.remaining }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                // Emoji + progress ring
                ZStack {
                    Circle()
                        .stroke(AppTheme.cardMid, lineWidth: 3)
                        .frame(width: 44, height: 44)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(AppTheme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: 44, height: 44)
                        .rotationEffect(.degrees(-90))
                    Text(goal.emoji).font(.system(.title3))
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(goal.name)
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundStyle(AppTheme.textPrimary)
                        Image(systemName: "pin.fill")
                            .font(.system(.caption2)).imageScale(.small)
                            .foregroundStyle(AppTheme.accent.opacity(0.7))
                    }
                    Text(String(format: loc("home.progress_to_go"),
                                Int(progress * 100),
                                CurrencyManager.shared.formatted(remaining, currency: goal.currency)))
                        .font(.system(.caption))
                        .foregroundStyle(AppTheme.textSecondary)
                }

                Spacer()

                HStack(spacing: 6) {
                    Text("\(CurrencyManager.shared.formatted(goal.currentValue, currency: goal.currency))")
                        .font(.system(.footnote, weight: .bold))
                        .foregroundStyle(AppTheme.accent)
                    if tappable {
                        Image(systemName: "chevron.right").font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                    }
                }
            }

            // Progress bar
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(AppTheme.cardMid).frame(height: 5)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(LinearGradient(colors: [AppTheme.accent, AppTheme.accent.opacity(0.6)],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: g.size.width * progress, height: 5)
                }
            }
            .frame(height: 5)
        }
        .padding(14)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.md)
            .stroke(AppTheme.accent.opacity(0.2), lineWidth: 1))
    }
}

// MARK: - Negative Balance Banner

struct NegativeBalanceBanner: View {
    let balance: Double
    var currency: String = CurrencyManager.shared.preferredCurrency

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(AppTheme.red.opacity(0.15)).frame(width: 42, height: 42)
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(.body)).foregroundStyle(AppTheme.red)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(loc("home.negative"))
                    .font(.system(.subheadline, weight: .semibold)).foregroundStyle(AppTheme.red)
                Text(String(
                    format: loc("balance.review"),
                    CurrencyManager.shared.formatted(
                        abs(balance),
                        currency: currency
                    )
                ))
                    .font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
            }
            Spacer()
        }
        .padding(14)
        .background(AppTheme.red.opacity(0.06), in: RoundedRectangle(cornerRadius: AppRadius.md))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.md).stroke(AppTheme.red.opacity(0.25), lineWidth: 1))
    }
}

// MARK: - Home Header

/// One candidate for Home's single attention slot.
///
/// `view` is type-erased because the candidates are unrelated banner types with
/// unrelated initialisers; ranking them in one list is the whole point, and
/// that needs them to share a type.
struct HomeAttentionItem: Identifiable {
    let id: String
    /// Lower wins. See `HomeView.attentionItems` for the policy.
    let rank: Int
    let view: AnyView
}

/// The quiet row standing in for every candidate that lost the slot. Tapping it
/// expands the rest in place rather than opening a sheet — the cards are
/// already built, and a sheet would make "3 hal lain" feel like a destination.
struct MoreAttentionRow: View {
    let count: Int
    let expanded: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                .font(.system(.caption2, weight: .semibold))
                .foregroundStyle(AppTheme.textSecondary)
            Text(expanded ? loc("home.attention_less")
                          : String(format: loc("home.attention_more"), count))
                .font(.system(.footnote))
                .foregroundStyle(AppTheme.textSecondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(AppTheme.cardDark.opacity(0.6), in: RoundedRectangle(cornerRadius: AppRadius.sm))
    }
}
