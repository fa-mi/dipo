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

/// What every account is worth once debts are taken off, for the grey line
/// under the total. Its arithmetic is one tap away: a bare figure,
/// especially a negative one, is alarming without its parts.
struct HomeNetWorth: Equatable {
    let amount: Double
    let currency: String
    /// "Cash Rp 4,8 jt + savings Rp 500 rb − debts Rp 2,4 jt".
    let breakdown: String
    /// Investments and assets it includes, one line each.
    var extras: [String] = []

    var text: String {
        String(format: loc("home.net_worth_line"),
               (amount < 0 ? "−" : "") + CurrencyManager.shared.formatted(Swift.abs(amount), currency: currency))
    }
}

/// The grey line under the total: net worth, which opens to its arithmetic,
/// and the days to payday. Shown on its own over the card when there is one
/// account and so no total row.
struct HomeTotalSubline: View {
    let netWorth: HomeNetWorth?
    let payday: String?
    @State private var open = false

    static func shows(netWorth: HomeNetWorth?, payday: String?) -> Bool {
        netWorth != nil || payday != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 0) {
                if let netWorth {
                    Button {
                        HapticManager.shared.tap()
                        withAnimation(.easeOut(duration: 0.2)) { open.toggle() }
                    } label: {
                        HStack(spacing: 3) {
                            Text(netWorth.text)
                                .foregroundStyle(netWorth.amount < 0 ? AppTheme.red : AppTheme.textSecondary)
                                .contentTransition(.numericText())
                                .animation(.easeOut(duration: 0.45), value: netWorth.amount)
                            Image(systemName: open ? "chevron.up" : "chevron.down")
                                .imageScale(.small)
                                .foregroundStyle(AppTheme.textSecondary)
                                .accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(loc("home.net_worth_hint"))
                }
                if netWorth != nil && payday != nil {
                    Text(verbatim: " · ").foregroundStyle(AppTheme.textSecondary)
                }
                if let payday {
                    Text(payday).foregroundStyle(AppTheme.textSecondary)
                }
            }
            .font(.system(.caption, weight: .medium))
            .lineLimit(1)
            .minimumScaleFactor(0.8)

            if open, let netWorth {
                VStack(alignment: .leading, spacing: 2) {
                    Text(netWorth.breakdown)
                    ForEach(netWorth.extras, id: \.self) { Text($0) }
                }
                .font(.system(.caption2))
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
            }
        }
    }
}

/// "Total balance · 3 accounts", then the total as the one big number on
/// Home, then the grey line. Only shown with two cash accounts or more: with
/// one, the total is that card's balance, shown right below it on the card.
struct HomeTotalRow: View {
    let total: Double
    let currency: String
    /// Cash accounts in the total. Credit cards are left out — what is owed
    /// on them is not money held — as Net Worth already does.
    let accounts: Int
    var netWorth: HomeNetWorth? = nil
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
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                // In sentence case, like every other label: spaced-out
                // capitals were harder to read and shouted the one word
                // above the money.
                Text(String(format: loc("home.total_accounts"), accounts))
                    .font(.system(.caption, weight: .medium))
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
            // The loudest thing on Home: what the person has.
            Text(hidden ? "••••••" : amountText)
                .font(.system(.largeTitle, weight: .bold).monospacedDigit())
                .foregroundStyle(total < 0 && !hidden ? AppTheme.red : AppTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.45), value: total)
                .accessibilityLabel(loc("home.total_balance"))
                // Hidden means not read out either.
                .accessibilityValue(hidden ? "" : amountText)
            if HomeTotalSubline.shows(netWorth: hidden ? nil : netWorth, payday: payday) {
                HomeTotalSubline(netWorth: hidden ? nil : netWorth, payday: payday)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
