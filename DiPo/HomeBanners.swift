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
            // DiPo's face alone; the rings and green glow round it were
            // decoration.
            DiPoLogo(size: 96, showBackground: true)
                .clipShape(Circle())

            VStack(spacing: 6) {
                Text(loc("home.get_started")).font(.system(.title2, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                Text(loc("home.get_started_sub"))
                    .font(.system(.subheadline)).foregroundStyle(AppTheme.textSecondary)
                    .multilineTextAlignment(.center).lineSpacing(3)
            }

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
            // The step's icon alone: ink when it is the one to do now, faded
            // while it waits, a tick once done.
            Image(systemName: isDone ? "checkmark" : icon)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(isActive || isDone ? AppTheme.textPrimary : AppTheme.textSecondary.opacity(0.5))
                .frame(width: ListRowMetrics.icon)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(isActive ? AppTheme.textPrimary : AppTheme.textSecondary.opacity(0.5))
                Text(subtitle).font(.system(.caption))
                    .foregroundStyle(AppTheme.textSecondary.opacity(isActive ? 0.8 : 0.4))
            }
            Spacer()
            // The button under the steps is the screen's one green.
            if isActive {
                ListChevron()
            } else if !isDone {
                Image(systemName: "lock.fill").font(.system(.caption2)).imageScale(.small)
                    .foregroundStyle(AppTheme.textSecondary.opacity(0.4))
            }
        }
        .padding(14)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
    }
}

// The banners that stood in Home's attention slot (a negative balance,
// setting up the salary, a detected bill, a pinned goal) are lines on
// Home's reminder line now: see HomeReminders.swift.
