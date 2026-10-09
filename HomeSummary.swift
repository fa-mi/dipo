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
    /// Of `expense`: debt paid down (instalments, card bills) and money put
    /// into savings or investments. Kept out of "Spending", because paying a
    /// Rp 3,9 jt card bill is not a month of overspending — it clears a debt.
    var putAway: Double = 0
    /// Money in that isn't income but the person added to this period's
    /// budget (see ExtraFunds). Not shown as income; it widens what is left.
    var extra: Double = 0
    let currency: String
    /// Names the window the figures cover — "Since payday 25 Aug", or "This
    /// month" when no salary schedule exists to define a cycle.
    let periodLabel: String
    /// Mirrors the card face's eye toggle. Hiding the balance while leaving
    /// income and expense on screen would defeat the point of hiding it —
    /// anyone reading over a shoulder learns the same thing either way.
    var isHidden: Bool = false
    /// One or two sentences under the figures: debt paid this period, or what
    /// kept the balance up when living costs passed income. Built by HomeView
    /// from PeriodCashBook, the same reasoning Statistics prints.
    var note: String? = nil
    var noteTone: NoteTone = .info
    /// Opens Statistics, where the period's cash book adds it all up. Nil when
    /// this card is not the one Statistics reads.
    var onDetails: (() -> Void)? = nil

    /// How the note reads. Red only when the balance itself is gone.
    enum NoteTone { case info, warn, danger }

    /// Spending on living: everything but debt paid and money put away.
    private var living: Double { max(expense - putAway, 0) }
    /// Share of income spent on living this cycle; nil without income.
    private var budgetIn: Double { income + extra }
    private var spentShare: Double? { budgetIn > 0 ? living / budgetIn : nil }
    private var remaining: Double { budgetIn - living }

    /// Green while there is room, orange from 80 % on. Not red: passing income
    /// is a warning, and the note says whether the balance covers it.
    private var shareTint: Color {
        guard let s = spentShare else { return AppTheme.accent }
        return s >= 0.8 ? AppTheme.orange : AppTheme.accent
    }

    private var noteTint: Color {
        switch noteTone {
        case .info:   return AppTheme.blue
        case .warn:   return AppTheme.orange
        case .danger: return AppTheme.red
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            // The window the figures cover, and how much of the income it has used.
            HStack(spacing: 10) {
                Image(systemName: "calendar")
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
                    .frame(width: 34, height: 34)
                    .background(AppTheme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 1) {
                    Text(loc("home.this_period"))
                        .font(.system(.subheadline, weight: .bold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(periodLabel)
                        .font(.system(.caption2))
                        .foregroundStyle(AppTheme.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 8)
                if let share = spentShare, !isHidden {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(loc("home.spent_of_income"))
                            .font(.system(.caption2))
                            .foregroundStyle(AppTheme.textSecondary)
                        HStack(spacing: 6) {
                            GeometryReader { g in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(AppTheme.cardMid)
                                    Capsule().fill(shareTint)
                                        .frame(width: g.size.width * min(share, 1))
                                }
                            }
                            .frame(height: 6)
                            Text(verbatim: "\(Int((share * 100).rounded()))%")
                                .font(.system(.caption, weight: .bold).monospacedDigit())
                                .foregroundStyle(AppTheme.textPrimary)
                        }
                    }
                    .frame(width: 128)
                    .animation(.easeOut(duration: 0.4), value: share)
                }
            }

            Rectangle().fill(AppTheme.cardMid).frame(height: 1)

            // Money coming IN points in, money going OUT points out — the
            // same directions the add-transaction form and Statistics use.
            HStack(spacing: 6) {
                column(icon: "arrow.down.left", label: loc("home.income"), amount: income, tint: AppTheme.flowIn)
                column(icon: "arrow.up.right", label: loc("home.spending"), amount: living, tint: AppTheme.flowOut)
                // Never a minus. What is left of income, or how far living
                // costs went past it — said in words, in blue or orange.
                // "Remaining −Rp 2.311.881" under a Rp 4,5 jt balance read as
                // being in debt.
                if remaining >= -0.5 {
                    column(icon: "equal", label: loc("home.left_of_income"), amount: max(remaining, 0),
                           tint: AppTheme.blue)
                } else {
                    column(icon: "exclamationmark", label: loc("home.over_income_label"), amount: -remaining,
                           tint: AppTheme.orange)
                }
            }

            if let note, !isHidden {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: noteTone == .info ? "creditcard.fill" : "exclamationmark.circle.fill")
                        .font(.system(.footnote))
                        .foregroundStyle(noteTint)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(note)
                            .font(.system(.caption))
                            .foregroundStyle(AppTheme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let onDetails {
                            Button {
                                HapticManager.shared.tap()
                                onDetails()
                            } label: {
                                HStack(spacing: 2) {
                                    Text(loc("home.flow_details"))
                                    Image(systemName: "chevron.right").imageScale(.small)
                                }
                                .font(.system(.caption, weight: .semibold))
                                .foregroundStyle(AppTheme.accent)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(noteTint.opacity(0.08), in: RoundedRectangle(cornerRadius: AppRadius.sm))
                .transition(.opacity)
            }
        }
        .padding(14)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
    }

    @ViewBuilder
    private func column(icon: String, label: String, amount: Double, tint: Color,
                        signed: Bool = false) -> some View {
        HStack(spacing: 7) {
            // A SOLID badge: a pale tint of the green washes out to near-white
            // on a light card. The glyph takes `onVividFill`, like every label
            // on a solid semantic fill.
            Image(systemName: icon)
                .font(.system(.caption, weight: .bold))
                .foregroundStyle(AppTheme.onVividFill)
                .frame(width: 28, height: 28)
                .background(tint, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(.caption2))
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1)
                Text(isHidden ? "••••" : figure(amount, signed: signed))
                    .font(.system(.footnote, weight: .bold))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    // Roll the digits when a new transaction moves them, so the
                    // entry the user just made is visibly connected to its effect.
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.4), value: amount)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    /// A signed figure carries a real minus sign in front of the currency, as
    /// Statistics prints it: "−Rp 273.500".
    private func figure(_ amount: Double, signed: Bool) -> String {
        guard signed else { return CurrencyManager.shared.formatted(amount, currency: currency) }
        return (amount < -0.5 ? "−" : "") + CurrencyManager.shared.formatted(abs(amount), currency: currency)
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
                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))

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
                        .background(AppTheme.flowOut, in: RoundedRectangle(cornerRadius: AppRadius.lg))
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
                        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
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
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.sm))

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
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
    }
}
