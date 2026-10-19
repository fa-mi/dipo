import SwiftUI

// MARK: - Home: the total, above the cards
//
// Home opens on one short row: what every cash account holds together, and
// the days to payday. The card carousel under it shows one account at a
// time, so the total was never on screen before. What is left of the period
// is NOT said here: the period card below says it, with its parts, and the
// same figure twice on one screen is noise (build 110 said it twice).

/// Home's preferences. Kept on this device, like the appearance mode: they
/// are choices about one screen, not records worth a backup.
enum HomePrefs {
    /// Every figure on Home behind dots, from the eye on the total row.
    static let hideBalancesKey = "home_hide_balances"
}

/// "TOTAL · 3 ACCOUNTS  Rp 4.830.607 … 9 days to payday". Only shown with two
/// cash accounts or more: with one, the total is that card's balance, shown
/// right below it on the card.
struct HomeTotalRow: View {
    let total: Double
    let currency: String
    /// Cash accounts in the total. Credit cards are left out — what is owed
    /// on them is not money held — as Net Worth already does.
    let accounts: Int
    let payday: String?
    @Binding var hidden: Bool

    /// Worth a row of its own only when it says something the card does not.
    static func shows(cashAccounts: Int) -> Bool { cashAccounts >= 2 }

    /// The days to payday, in words. Nil without a salary schedule.
    static func paydayText(days: Int?) -> String? {
        guard let days, days >= 0 else { return nil }
        switch days {
        case 0:  return loc("home.hero.payday_today")
        case 1:  return loc("home.hero.payday_tomorrow")
        default: return String(format: loc("home.hero.payday_in"), days)
        }
    }

    private var amountText: String {
        (total < 0 ? "-" : "") + CurrencyManager.shared.formatted(Swift.abs(total), currency: currency)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(String(format: loc("home.total_accounts"), accounts)
                            .uppercased(with: LanguageManager.shared.currentLocale))
                        .font(.system(.caption2, weight: .semibold))
                        .tracking(1.1)
                        .foregroundStyle(AppTheme.textSecondary)
                        .lineLimit(1)
                    Button {
                        HapticManager.shared.tap()
                        withAnimation(.easeOut(duration: 0.2)) { hidden.toggle() }
                    } label: {
                        Image(systemName: hidden ? "eye.slash" : "eye")
                            .font(.system(.caption2, weight: .semibold))
                            .foregroundStyle(AppTheme.textSecondary)
                            .frame(width: 26, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(ScaleButtonStyle())
                    .accessibilityLabel(loc(hidden ? "home.show_all" : "home.hide_all"))
                }
                Text(hidden ? "••••••" : amountText)
                    .font(.system(.title2, weight: .bold).monospacedDigit())
                    .foregroundStyle(total < 0 && !hidden ? AppTheme.red : AppTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.45), value: total)
                    .accessibilityLabel(loc("home.total_balance"))
                    // Hidden means not read out either.
                    .accessibilityValue(hidden ? "" : amountText)
            }
            Spacer(minLength: 8)
            if let payday {
                Text(payday)
                    .font(.system(.caption, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(AppTheme.cardDark, in: Capsule())
                    .padding(.bottom, 2)
            }
        }
    }
}
