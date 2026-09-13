import SwiftUI

// MARK: - Month Flow Card

/// Income and expense for the selected card, this calendar month, side by side.
///
/// Home could always show a balance and a list of transactions, but never the
/// two figures that explain the distance between them. "Rp 4.2 jt" answers
/// *where you are*; it takes income and expense together to answer *which way
/// you are moving*, and that is the question a home screen is actually for.
///
/// Both halves are read from the SAME transactions the list below shows, in the
/// card's own currency, so the three numbers on this screen cannot disagree.
struct MonthFlowCard: View {
    let income: Double
    let expense: Double
    let currency: String
    /// Mirrors the card face's eye toggle. Hiding the balance while leaving
    /// income and expense on screen would defeat the point of hiding it —
    /// anyone reading over a shoulder learns the same thing either way.
    var isHidden: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            half(icon: "arrow.up.right",
                 label: loc("home.income"),
                 amount: income,
                 tint: AppTheme.accent)

            // Hairline, not a gap: the two halves are one comparison.
            Rectangle()
                .fill(AppTheme.cardMid)
                .frame(width: 1, height: 46)

            half(icon: "arrow.down.left",
                 label: loc("home.expense"),
                 amount: expense,
                 tint: AppTheme.red)
        }
        .padding(.vertical, 14)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 20))
    }

    @ViewBuilder
    private func half(icon: String, label: String, amount: Double, tint: Color) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.13))
                    .frame(width: 34, height: 34)
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.textSecondary)
                Text(isHidden ? "••••••"
                              : CurrencyManager.shared.formatted(amount, currency: currency))
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    // Roll the digits when a new transaction moves them, so the
                    // entry the user just made is visibly connected to its effect.
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.4), value: amount)
                // Full textSecondary, not a faded one. At 75% it measures
                // 3.40:1 in light mode and 3.39:1 in dark — under the 4.5 floor
                // for text this small. Size already makes it subordinate;
                // fading it as well only made it hard to read.
                Text(loc("home.this_month"))
                    .font(.system(size: 10))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
    }
}
