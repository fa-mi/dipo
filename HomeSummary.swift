import SwiftUI
import SwiftData

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
    /// Today as day N of the M the period runs, for the subtitle and the
    /// mark on the line. Nil hides both.
    var cycleDay: (day: Int, of: Int)? = nil
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
    /// The period's money: income, and money added to this period's budget.
    private var budgetIn: Double { income + extra }
    /// Shares of it spent on living, and gone to debts paid and money put
    /// away: the line's two fills.
    private var livingShare: Double { budgetIn > 0 ? living / budgetIn : 0 }
    private var putAwayShare: Double { budgetIn > 0 ? putAway / budgetIn : 0 }
    private var remaining: Double { Self.remaining(income: income, expense: expense, putAway: putAway, extra: extra) }
    private var left: Double { Self.left(income: income, expense: expense, putAway: putAway, extra: extra) }

    /// What is actually left of the period's money: income and added money,
    /// less living costs AND what went to debts and savings. Fahmi read
    /// "Spending Rp 5.353.060 · Left of income Rp 13.646.940" on a period
    /// where Rp 5.750.000 had also gone to his cards, and asked why so little
    /// had been spent when so much of the income was gone. Debt paid is still
    /// not spending, but it is not left either. Negative when the debts and
    /// savings took more than the income had room for.
    static func left(income: Double, expense: Double, putAway: Double, extra: Double) -> Double {
        remaining(income: income, expense: expense, putAway: putAway, extra: extra) - putAway
    }

    /// What is left of the period's money once living costs are out: income
    /// and added money, less spending other than debt paid and money put
    /// away. Negative when living costs passed it.
    static func remaining(income: Double, expense: Double, putAway: Double, extra: Double) -> Double {
        income + extra - max(expense - putAway, 0)
    }

    /// The period line's three figures, in whole percent of the money that
    /// came in: all of it used, then its two parts, living costs and what
    /// went to debts and savings. The parts are cut from the rounded whole,
    /// so "Spending 51%" and "Debts & savings 30%" always add up to the
    /// "81%" printed above them. Nil without income to measure against.
    static func percents(income: Double, expense: Double, putAway: Double,
                         extra: Double) -> (used: Int, living: Int, putAway: Int)? {
        let budget = income + extra
        guard budget > 0 else { return nil }
        let living = max(expense - putAway, 0)
        let used = Int(((living + max(putAway, 0)) / budget * 100).rounded())
        let livingPct = min(Int((living / budget * 100).rounded()), used)
        return (used, livingPct, used - livingPct)
    }

    /// Where today's mark sits on the line: the share of the period's days
    /// gone, today counted. Day 22 of 33 sits two thirds along.
    static func todayMark(day: Int, of total: Int) -> Double {
        guard total > 0 else { return 0 }
        return min(max(Double(day) / Double(total), 0), 1)
    }

    private var noteTint: Color {
        switch noteTone {
        case .info:   return AppTheme.blue
        case .warn:   return AppTheme.orange
        case .danger: return AppTheme.red
        }
    }

    /// The figures on the line, or nil when there is nothing to draw: no
    /// income yet, or the balance hidden.
    private var shown: (used: Int, living: Int, putAway: Int)? {
        isHidden ? nil : Self.percents(income: income, expense: expense, putAway: putAway, extra: extra)
    }

    /// The period's dates: since when, and which day of it today is.
    private var subtitle: String {
        guard let d = cycleDay else { return periodLabel }
        return periodLabel + " · " + String(format: loc("stats.day_of"), d.day, d.of)
    }

    var body: some View {
        VStack(spacing: 12) {
            // The window the figures cover, and how much of its money is used.
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "calendar")
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
                    .frame(width: 28)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(loc("home.this_period"))
                        .font(.system(.subheadline, weight: .bold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(subtitle)
                        .font(.system(.caption2))
                        .foregroundStyle(AppTheme.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if let pct = shown {
                    usedFigure(pct.used)
                }
            }

            // The line: what is used of the period's money, against how much
            // of the period has gone. It took the hourglass's place, and the
            // hairline's: one quiet mark that says more than either did.
            if let pct = shown {
                periodLine(pct)
            } else {
                Rectangle().fill(AppTheme.cardMid).frame(height: 1)
            }

            // Money coming IN points in, money going OUT points out — the
            // same directions the add-transaction form and Statistics use.
            //
            // Three figures side by side, each under its label, so a label
            // has its column's width and may take a second line ("Sisa /
            // pemasukan"); the figures sit on one baseline below.
            HStack(alignment: .top, spacing: 12) {
                tile(icon: "arrow.down.left", label: loc("home.income"), amount: income,
                     tint: AppTheme.flowIn, ink: AppTheme.flowIn)
                tile(icon: "arrow.up.right", label: loc("home.spending"), amount: living,
                     tint: AppTheme.flowOut, ink: AppTheme.textPrimary)
                // Never a minus. What is left of income, or how far living
                // costs went past it — said in words, the second in orange.
                // "Remaining −Rp 2.311.881" under a Rp 4,5 jt balance read as
                // being in debt.
                if remaining >= -0.5 && left >= -0.5 {
                    tile(icon: "equal", label: loc("home.left_of_income"), amount: max(left, 0),
                         tint: AppTheme.blue, ink: AppTheme.textPrimary)
                } else if remaining >= -0.5 {
                    // Living costs fit the income, but debts and savings took
                    // more than was left: the rest came from the balance.
                    // Blue, not orange: paying debt down is not overspending.
                    tile(icon: "arrow.uturn.down", label: loc("home.from_balance"), amount: -left,
                         tint: AppTheme.blue, ink: AppTheme.textPrimary)
                } else {
                    tile(icon: "exclamationmark", label: loc("home.over_income_label"), amount: -remaining,
                         tint: AppTheme.orange, ink: AppTheme.orange)
                }
            }
            .fixedSize(horizontal: false, vertical: true)

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
                                .foregroundStyle(AppTheme.textPrimary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 2)
                .transition(.opacity)
            }
        }
        .padding(14)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
    }

    /// Living costs past income: the one case the line and its figure say in
    /// orange, as the "over income" tile below does. Debts paid from the
    /// balance stay in ink: paying debt down is not overspending.
    private var overIncome: Bool { remaining < -0.5 }

    /// "81%" over "Used", where the hourglass stood. The one large number on
    /// the card: how much of the period's money is gone.
    private func usedFigure(_ used: Int) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(verbatim: "\(used)")
                    .font(.system(.title2, weight: .bold).monospacedDigit())
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.4), value: used)
                Text(verbatim: "%")
                    .font(.system(.footnote, weight: .bold))
            }
            .foregroundStyle(overIncome ? AppTheme.orange : AppTheme.textPrimary)
            Text(loc("home.used_short"))
                .font(.system(.caption2))
                .foregroundStyle(AppTheme.textSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(loc("home.spent_of_income") + " \(used)%")
    }

    /// The line and what each of its marks is. Ink for living costs, blue for
    /// debts paid and money put away (the blue of the note about them), and
    /// a short upright mark for today. Nothing else is coloured.
    private func periodLine(_ pct: (used: Int, living: Int, putAway: Int)) -> some View {
        let mark = cycleDay.map { Self.todayMark(day: $0.day, of: $0.of) }
        let livingInk = overIncome ? AppTheme.orange : AppTheme.textPrimary
        return VStack(alignment: .leading, spacing: 8) {
            PeriodLine(living: livingShare, putAway: putAwayShare, today: mark, livingInk: livingInk)
                .animation(.easeOut(duration: 0.6), value: livingShare + putAwayShare)
            WrapFlow(spacing: 14, rowSpacing: 4) {
                lineKey(swatch: livingInk, text: loc("home.spending") + " \(pct.living)%")
                if putAway > 0.5 {
                    lineKey(swatch: AppTheme.blue, text: loc("home.debts_and_savings") + " \(pct.putAway)%")
                }
                if mark != nil {
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(AppTheme.textPrimary)
                            .frame(width: 2, height: 10)
                        Text(loc("home.today_mark"))
                    }
                    .font(.system(.caption2))
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(lineLabel(pct))
    }

    private func lineKey(swatch: Color, text: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2)
                .fill(swatch)
                .frame(width: 7, height: 7)
            Text(text)
        }
        .font(.system(.caption2))
        .foregroundStyle(AppTheme.textSecondary)
        .lineLimit(1)
        .fixedSize()
    }

    /// The line in words, for VoiceOver: the parts, then the day.
    private func lineLabel(_ pct: (used: Int, living: Int, putAway: Int)) -> String {
        var parts = [loc("home.spending") + " \(pct.living)%"]
        if putAway > 0.5 { parts.append(loc("home.debts_and_savings") + " \(pct.putAway)%") }
        if let d = cycleDay { parts.append(String(format: loc("stats.day_of"), d.day, d.of)) }
        return parts.joined(separator: ", ")
    }

    /// One figure: what it is, with its direction in its own colour, and the
    /// amount. Nothing behind it: the badge and the wash each tile wore said
    /// the colour again. Only money coming in is green (`ink`); spending and
    /// what is left are in ink, and going past income is orange.
    private func tile(icon: String, label: String, amount: Double, tint: Color, ink: Color,
                      signed: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: icon)
                    .font(.system(.caption2, weight: .bold))
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(label)
                    .font(.system(.caption2))
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Text(isHidden ? "••••" : figure(amount, signed: signed))
                .font(.system(.footnote, weight: .bold))
                .foregroundStyle(ink)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                // Roll the digits when a new transaction moves them, so the
                // entry the user just made is visibly connected to its effect.
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.4), value: amount)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }

    /// A signed figure carries a real minus sign in front of the currency, as
    /// Statistics prints it: "−Rp 273.500".
    private func figure(_ amount: Double, signed: Bool) -> String {
        guard signed else { return CurrencyManager.shared.formatted(amount, currency: currency) }
        return (amount < -0.5 ? "−" : "") + CurrencyManager.shared.formatted(abs(amount), currency: currency)
    }
}

/// Home's period line: a 6-point track, filled from the left with living
/// costs and then debts and savings, as shares of the period's money, with an
/// upright mark at today. Where the fill ends against the mark is the whole
/// reading: short of it, the money is lasting longer than the days.
private struct PeriodLine: View {
    let living: Double
    let putAway: Double
    let today: Double?
    let livingInk: Color

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let l = min(max(living, 0), 1)
            let p = min(max(putAway, 0), 1 - l)
            ZStack(alignment: .leading) {
                Capsule().fill(AppTheme.cardMid).frame(height: 6)
                HStack(spacing: 0) {
                    Rectangle().fill(livingInk).frame(width: w * l)
                    Rectangle().fill(AppTheme.blue).frame(width: w * p)
                }
                .frame(width: w, height: 6, alignment: .leading)
                .clipShape(Capsule())
                if let today {
                    // A gap in the card's own colour on each side keeps the
                    // mark sharp where it crosses the fill.
                    ZStack {
                        RoundedRectangle(cornerRadius: 2).fill(AppTheme.cardDark).frame(width: 6, height: 18)
                        RoundedRectangle(cornerRadius: 1).fill(AppTheme.textPrimary).frame(width: 2, height: 14)
                    }
                    .offset(x: min(max(w * today - 3, -2), w - 4))
                }
            }
            .frame(width: w, height: g.size.height)
        }
        .frame(height: 18)
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

    @Environment(\.modelContext) private var context
    /// Every row of the card payment `tx` is part of, which go with it
    /// (deleteTransactionWithGoalRollback); just `tx` otherwise.
    @State private var payment: [TxRecord] = []
    private var isPayment: Bool { payment.count > 1 }
    /// The payment's rows on the card shown here.
    private var here: [TxRecord] { payment.filter { ($0.amount < 0) == (tx.amount < 0) } }

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
                Text(loc(isPayment ? "tx.delete_payment_prompt" : "tx.delete_prompt"))
                    .font(.system(.title3, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(loc("tx.delete_confirm"))
                    .font(.system(.footnote))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .multilineTextAlignment(.center)

            // The row itself, exactly as it looked in the list.
            TxRow(tx: tx, sourceCard: card, showCard: false, parts: here.count > 1 ? here : [])
                .padding(14)
                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))

            if let card {
                impactRow(card)
            }

            if isPayment {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "creditcard")
                        .font(.system(.footnote))
                        .foregroundStyle(AppTheme.textSecondary)
                    Text(loc("tx.delete_payment_note"))
                        .font(.system(.caption))
                        .foregroundStyle(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
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
        .onAppear { payment = CardPaymentLegs.all(of: tx, in: context) }
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
        // A card payment's parts on this card go together.
        let v = isPayment ? CardPaymentLegs.total(here, in: cur) : cm.convert(tx.amount, from: tx.currency, to: cur)

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
