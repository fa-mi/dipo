import SwiftUI

// MARK: - Month Flow Card

/// Income and expense for the selected card over the current pay cycle.
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
    /// Names the window the figures cover — "Since payday 25 Aug", or "This
    /// month" when no salary schedule exists to define a cycle.
    let periodLabel: String
    /// Mirrors the card face's eye toggle. Hiding the balance while leaving
    /// income and expense on screen would defeat the point of hiding it —
    /// anyone reading over a shoulder learns the same thing either way.
    var isHidden: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            half(icon: "arrow.up.right",
                 label: loc("home.income"),
                 amount: income,
                 tint: AppTheme.flowIn)

            // Hairline, not a gap: the two halves are one comparison.
            Rectangle()
                .fill(AppTheme.cardMid)
                .frame(width: 1, height: 46)

            half(icon: "arrow.down.left",
                 label: loc("home.expense"),
                 amount: expense,
                 tint: AppTheme.flowOut)
        }
        .padding(.vertical, 14)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 20))
    }

    @ViewBuilder
    private func half(icon: String, label: String, amount: Double, tint: Color) -> some View {
        HStack(spacing: 10) {
            // A SOLID badge, like the battery fill while charging — a pale
            // tint of systemGreen washed out to near-white on a light card.
            // The glyph is dark on both colours in both modes, which keeps it
            // legible where a white glyph on systemGreen would not be (2.2:1).
            ZStack {
                Circle()
                    .fill(tint)
                    .frame(width: 34, height: 34)
                Image(systemName: icon)
                    .font(.system(.subheadline, weight: .bold))
                    .foregroundStyle(AppTheme.onVividFill)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(.caption))
                    .foregroundStyle(AppTheme.textSecondary)
                Text(isHidden ? "••••••"
                              : CurrencyManager.shared.formatted(amount, currency: currency))
                    .font(.system(.callout, weight: .bold))
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
                Text(periodLabel)
                    .font(.system(.caption2))
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Delete Transaction Sheet

/// The confirmation shown after a swipe-to-delete.
///
/// It replaces a system action sheet that asked "Delete transaction?" and
/// nothing else. That question could not be answered well: it did not say
/// WHICH transaction (a full swipe fires it before the row has finished
/// sliding, so the eye has lost track of it), and it did not say what deleting
/// would DO. For a money app the second matters more — deleting an expense
/// puts money back on the card, and seeing "Rp 4.207.837 → Rp 4.227.837" is how
/// someone notices they are about to delete the wrong row.
struct DeleteTransactionSheet: View {
    let tx: TxRecord
    let card: BankCard?
    let onConfirm: () -> Void
    let onCancel: () -> Void

    /// The sheet sizes itself to its content rather than a fixed detent, so it
    /// neither clips on large Dynamic Type nor leaves a half-empty panel.
    @State private var contentHeight: CGFloat = 420

    private var isGoalDeposit: Bool { tx.notes == "tx.note.goal_deposit" && tx.amount < 0 }

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(AppTheme.flowOut)
                    .frame(width: 56, height: 56)
                Image(systemName: "trash.fill")
                    .font(.system(.title2, weight: .semibold))
                    .foregroundStyle(AppTheme.onVividFill)
            }
            .padding(.top, 8)

            VStack(spacing: 6) {
                Text(loc("tx.delete_prompt"))
                    .font(.system(.title3, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(loc("tx.delete_confirm"))
                    .font(.system(.footnote))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .multilineTextAlignment(.center)

            // The row itself, exactly as it looked in the list.
            TxRow(tx: tx, sourceCard: card, showCard: false, animateEntrance: false)
                .padding(14)
                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 18))

            if let card {
                impactRow(card)
            }

            if isGoalDeposit {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "target")
                        .font(.system(.footnote))
                        .foregroundStyle(AppTheme.textSecondary)
                    Text(loc("tx.delete_goal_note"))
                        .font(.system(.caption))
                        .foregroundStyle(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }

            VStack(spacing: 10) {
                Button {
                    onConfirm()
                } label: {
                    Text(loc("common.delete"))
                        .font(.system(.callout, weight: .bold))
                        .foregroundStyle(AppTheme.onVividFill)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(AppTheme.flowOut, in: RoundedRectangle(cornerRadius: 18))
                }
                .buttonStyle(ScaleButtonStyle())

                // Here a second button under the destructive one is right: it
                // is the SAFE choice, and it should be the easy one to hit.
                Button {
                    HapticManager.shared.tap()
                    onCancel()
                } label: {
                    Text(loc("tx.delete_keep"))
                        .font(.system(.callout, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 18))
                }
                .buttonStyle(ScaleButtonStyle())
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 10)
        // Take the IDEAL height, not whatever the current detent offers.
        // Without this, content taller than the starting 420pt is compressed
        // to fit, the measurement reads 420 back, and the sheet never grows —
        // large Dynamic Type would truncate the very text explaining the delete.
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 + 24 }
        .presentationDetents([.height(contentHeight)])
        .presentationDragIndicator(.visible)
        .presentationBackground(AppTheme.bg)
        .presentationCornerRadius(28)
        // No haptic on appear: a full swipe has already fired its warning the
        // instant it crossed the threshold, and a second one here read as a
        // stutter. Each entry point owns its own feedback.
    }

    /// What the card looks like after the delete.
    ///
    /// A cash card shows before → after, because its balance is one canonical
    /// figure. A credit card shows only the change: what it owes can also carry
    /// instalment principal that other screens fold in, and printing a second
    /// "after" figure here would invite a mismatch with them.
    @ViewBuilder
    private func impactRow(_ card: BankCard) -> some View {
        let cur = card.resolvedCurrency
        let cm = CurrencyManager.shared
        let v = cm.convert(tx.amount, from: tx.currency, to: cur)

        HStack(spacing: 12) {
            LinearGradient(colors: [Color(hex: card.gradientStart), Color(hex: card.gradientEnd)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 9))

            if card.isCreditCard {
                let counts = tx.date >= (card.creditSince ?? .distantPast)
                // Removing a purchase (v < 0) lowers what is owed.
                let delta = counts ? -v : 0
                VStack(alignment: .leading, spacing: 2) {
                    Text(CardLabel.title(card))
                        .font(.system(.caption))
                        .foregroundStyle(AppTheme.textSecondary)
                    Text(String(format: loc(delta <= 0 ? "tx.delete_owed_down" : "tx.delete_owed_up"),
                                cm.formatted(Swift.abs(delta), currency: cur)))
                        .font(.system(.subheadline, weight: .bold))
                        .foregroundStyle(delta <= 0 ? AppTheme.flowIn : AppTheme.flowOut)
                }
            } else {
                let before = card.computedBalance()
                let after = before - v
                let signed = { (x: Double) in (x < 0 ? "-" : "") + cm.formatted(Swift.abs(x), currency: cur) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: loc("tx.delete_balance_of"), CardLabel.title(card)))
                        .font(.system(.caption))
                        .foregroundStyle(AppTheme.textSecondary)
                    HStack(spacing: 6) {
                        Text(signed(before))
                            .font(.system(.footnote))
                            .foregroundStyle(AppTheme.textSecondary)
                            .strikethrough(color: AppTheme.textSecondary)
                        Image(systemName: "arrow.right")
                            .font(.system(.caption2, weight: .bold)).imageScale(.small)
                            .foregroundStyle(AppTheme.textSecondary)
                        Text(signed(after))
                            .font(.system(.subheadline, weight: .bold))
                            .foregroundStyle(after >= before ? AppTheme.flowIn : AppTheme.flowOut)
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 18))
    }
}
