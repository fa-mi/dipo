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

// The banners that stood in Home's attention slot (a negative balance,
// setting up the salary, a detected bill, a pinned goal) are lines on
// Home's reminder line now: see HomeReminders.swift.
