import SwiftUI
import SwiftData

// Part of StatisticsView. The main page: the hero (what went on living, the
// balance, payday), by month, where it went, worth knowing, the working.

extension StatisticsView {
    // MARK: Main page

    var mainPage: some View {
        ZStack {
            AppTheme.bg.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                Group {
                    // Room for two phone columns (the Duo opened and turned):
                    // how much and am I fine on the left, where it went and
                    // what's worth knowing on the right.
                    if pageColumns == 2 {
                        HStack(alignment: .top, spacing: AppLayout.columnGap) {
                            VStack(alignment: .leading, spacing: 16) {
                                header
                                spendHero
                            }
                            .frame(maxWidth: AppLayout.phoneContentMaxWidth)
                            VStack(alignment: .leading, spacing: 26) {
                                monthBars
                                categoriesCard
                                notesCard
                                detailLink
                            }
                            .frame(maxWidth: AppLayout.phoneContentMaxWidth)
                        }
                        .padding(.bottom, 40)
                    } else {
                        // The hero, then sections on the page itself: by month,
                        // where it went, worth knowing, the working.
                        VStack(alignment: .leading, spacing: 26) {
                            VStack(alignment: .leading, spacing: 16) {
                                header
                                spendHero
                            }
                            monthBars
                            categoriesCard
                            notesCard
                            detailLink
                            Spacer(minLength: 110)
                        }
                        // Centred and capped, like Home (AppLayout).
                        .frame(maxWidth: AppLayout.phoneContentMaxWidth - 2 * AppLayout.pageMargin)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 20)
                .frame(maxWidth: .infinity)
                .containerRelativeFrame(.horizontal)
            }
        }
    }

    var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(loc("stats.title"))
                        .font(.system(.title, weight: .bold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(periodSubtitle)
                        .font(.system(.footnote))
                        .foregroundStyle(AppTheme.textSecondary)
                    // Said once, where the screen names itself: the figures
                    // below include the cards the main card pays bills from.
                    if let bills = billCardsLabel {
                        Text(String(format: loc("stats.with_bill_cards"), bills))
                            .font(.system(.caption))
                            .foregroundStyle(AppTheme.textSecondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
                Button {
                    HapticManager.shared.tap()
                    showExportSheet = true
                } label: {
                    // A plain icon: the round tile behind it said "button"
                    // a second time.
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(.body, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(loc("a11y.export"))
                .buttonStyle(ScaleButtonStyle())
            }

            // The period is context, not content: one quiet chip.
            Menu {
                ForEach(availablePeriods, id: \.self) { period in
                    Button {
                        HapticManager.shared.tap()
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                            selectedPeriod = period
                            if period == .custom { showCustomPicker = true }
                        }
                    } label: {
                        if selectedPeriod == period {
                            Label(period.title, systemImage: "checkmark")
                        } else {
                            Text(period.title)
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                        .font(.system(.caption, weight: .semibold))
                        .foregroundStyle(AppTheme.textSecondary)
                    Text(selectedPeriod.title)
                        .font(.system(.footnote, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Image(systemName: "chevron.down")
                        .font(.system(.caption2, weight: .semibold)).imageScale(.small)
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
        }
    }

    // MARK: 0 · The headline, at a glance
    //
    // Opens on what reassures and is true: whether the money lasts to payday,
    // the balance, and what it should be at payday. Then how living costs
    // compare with income — debt paid down and money put away kept apart, since
    // neither is spending on living — and the period's cash book, which adds it
    // all up to the balance.
    //
    // Red is kept for one case: the balance is on course to run out before
    // payday. A Rp 3,9 jt credit card payment folded into "spending" used to
    // put a large red minus at the top of a healthy card, and a person with
    // money in the bank read it as being in trouble.

    var spendHero: some View {
        let book = cashBook
        let outlook = book.flatMap { paydayOutlook($0) }
        let danger = book.map { (outlook?.end ?? $0.end) < 0.5 } ?? false
        let spent = book?.living ?? filteredExpenses
        return VStack(alignment: .leading, spacing: 14) {
            // What went on living this period is the one big number. The
            // balance it leaves, and whether it lasts to payday, come after.
            VStack(alignment: .leading, spacing: 4) {
                Text(loc("stats.spent_label"))
                    .font(.system(.footnote, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary)
                Text(money(spent))
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(heroFigure(danger: danger))
                    .contentTransition(.numericText())
                    .minimumScaleFactor(0.5).lineLimit(1)
                if let line = StatsLines.comparison(periodLivingChange) {
                    Text(line)
                        .font(.system(.footnote))
                        .foregroundStyle(AppTheme.textPrimary)
                }
                if let line = StatsLines.days(today: todaySpend, typical: typicalDailySpend, money: money) {
                    Text(line)
                        .font(.system(.caption))
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }

            if livingFunds > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    // The existing gauge, not a plain bar: it carries the tick for
                    // how much of the period has elapsed, so spending ahead of the
                    // calendar is visible rather than merely counted.
                    SpendGauge(fraction: livingRatio,
                               timeMarker: periodProgress.map { Double($0.elapsed) / Double($0.total) },
                               overColor: danger ? AppTheme.red : AppTheme.orange)
                    Text(String(format: loc("stats.pct_of_income"), incomeUsedPct))
                        .font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
            }

            if let book { balanceLines(book, outlook: outlook) }
            if let book, livingFunds > 0 { livingBox(book, danger: danger) }
            if let book, book.debtPaid >= 0.5 || book.invested >= 0.5 { debtBox(book) }

            // Where this period is heading, in one sentence.
            if let line = paceLine(book) {
                sentence(line.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                         line.ok ? AppTheme.accent : AppTheme.orange, line.text)
            } else if livingFunds <= 0 {
                Label(loc("stats.no_income_hint"), systemImage: "info.circle")
                    .font(.system(.caption))
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let book { cashBookDisclosure(book) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background {
            // The one gradient on the screen: the web hero's field, peach
            // when the balance is heading below zero. Dark in both themes,
            // as a card face is, so everything on it reads as in dark mode.
            RoundedRectangle(cornerRadius: AppRadius.xl).fill(AppTheme.flowGround)
                .overlay { FlowField(danger: danger) }
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.xl))
                .overlay(RoundedRectangle(cornerRadius: AppRadius.xl)
                    .stroke(danger ? AppTheme.flowPeach.opacity(0.28) : AppTheme.flowMint.opacity(0.16), lineWidth: 1))
                .shadow(color: (danger ? AppTheme.flowPeach : AppTheme.flowPine).opacity(0.22), radius: 18, y: 10)
        }
        .environment(\.colorScheme, .dark)
    }

    /// The balance the period leaves, and for a running pay cycle whether it
    /// lasts to payday and what payday should find. Red only when it may not.
    func balanceLines(_ book: PeriodCashBook, outlook: (payday: Date, end: Double)?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(periodRunsToToday ? ScopeBalance.nowLabel(cards: scopeCards.count) : loc("stats.recon_end"))
                    .foregroundStyle(AppTheme.textSecondary)
                Text(signedMoney(book.end))
                    .fontWeight(.semibold)
                    .foregroundStyle(AppTheme.textPrimary)
                    .contentTransition(.numericText())
            }
            .font(.system(.subheadline))
            .lineLimit(1).minimumScaleFactor(0.8)
            if let outlook {
                let safe = outlook.end >= 0.5
                Text(String(format: loc(safe ? "stats.safe_until" : "stats.risk_until"), dayMonth(outlook.payday))
                     + " · " + String(format: loc("stats.at_payday"), signedMoney(outlook.end)))
                    .font(.system(.caption, weight: safe ? .regular : .semibold))
                    .foregroundStyle(safe ? AppTheme.textSecondary : AppTheme.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// One sentence on the hero: its icon in its colour, nothing behind it.
    func sentence(_ icon: String, _ tint: Color, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(.subheadline))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(.footnote, weight: .medium))
                .foregroundStyle(AppTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The cash book, one tap away: where the balance began, what came in and
    /// went out, and where it stands. Open by itself when the opening balance
    /// is below zero, since that needs a fix.
    @ViewBuilder
    func cashBookDisclosure(_ book: PeriodCashBook) -> some View {
        let needsFix = book.start < -0.5 && !(selectedCard?.isCreditCard ?? true)
        let open = showCashBook || needsFix
        VStack(alignment: .leading, spacing: 8) {
            if !needsFix {
                Button {
                    HapticManager.shared.tap()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { showCashBook.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Text(loc(showCashBook ? "stats.book_hide" : "stats.book_show"))
                        Image(systemName: "chevron.down")
                            .imageScale(.small)
                            .rotationEffect(.degrees(showCashBook ? 180 : 0))
                    }
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if open {
                cashBookView(book)
                    .transition(.opacity)
            }
        }
    }

    /// White fading to frost, or blush to peach when the balance runs out —
    /// the web's balance figure.
    func heroFigure(danger: Bool) -> LinearGradient {
        danger
            ? LinearGradient(stops: [.init(color: AppTheme.flowBlush, location: 0.2),
                                     .init(color: AppTheme.flowPeach, location: 1)],
                             startPoint: .top, endPoint: .bottom)
            : LinearGradient(stops: [.init(color: AppTheme.textPrimary, location: 0.3),
                                     .init(color: AppTheme.flowFrost, location: 1)],
                             startPoint: .top, endPoint: .bottom)
    }

    func signedMoney(_ v: Double) -> String {
        (v < -0.5 ? "−" : "") + money(abs(v))
    }

    func dayMonth(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = LanguageManager.shared.currentLocale
        f.setLocalizedDateFormatFromTemplate("d MMM")
        return f.string(from: d)
    }

    /// For a running pay cycle: the next payday, and the balance it should
    /// find — today's less the spending still to come at the current pace.
    /// Money in or out that is not income or spending can't be foreseen and
    /// isn't guessed at.
    func paydayOutlook(_ book: PeriodCashBook) -> (payday: Date, end: Double)? {
        guard periodRunsToToday, let projected = projectedSpend, let p = periodProgress,
              let payday = Calendar.current.date(byAdding: .day, value: p.total,
                                                 to: Calendar.current.startOfDay(for: effectiveRange.start))
        else { return nil }
        return (payday, book.endAtPayday(projected: projected))
    }

    /// Living costs over income, for the gauge: debt paid and money put away
    /// left out, as in the cash book.
    var livingRatio: Double {
        guard livingFunds > 0 else { return 0 }
        return (cashBook?.living ?? filteredExpenses) / livingFunds
    }

    /// Money in that isn't income but the person added to this period's
    /// budget (ExtraFunds).
    var periodExtraFunds: Double {
        ExtraFunds.total(in: filteredTx, from: .distantPast, currency: displayCurrency)
    }

    /// What living costs are measured against: income, plus that.
    var livingFunds: Double { filteredIncome + periodExtraFunds }

    /// Share of income spent on living, as on Home: past 100 when living costs
    /// pass income, and held below 100 until the income is actually all gone.
    var incomeUsedPct: Int {
        guard livingFunds > 0 else { return 0 }
        return PeriodCashBook.usedPct(ratio: livingRatio)
    }

    /// Living costs against income, in one sentence, coloured by what it
    /// means: green within income, orange past it, red only when the balance
    /// itself is in danger.
    func livingBox(_ book: PeriodCashBook, danger: Bool) -> some View {
        let over = book.livingNet < -0.5
        let text = book.livingSentence(money: money)
        let tint = !over ? AppTheme.accent : (danger ? AppTheme.red : AppTheme.orange)
        return sentence(over ? "exclamationmark.circle.fill" : "checkmark.circle.fill", tint, text)
    }

    /// Debt paid down and money put away — named as what they are, in blue,
    /// rather than counted as overspending.
    func debtBox(_ book: PeriodCashBook) -> some View {
        sentence("creditcard.fill", AppTheme.blue, book.debtSentence(money: money) ?? "")
    }

    // MARK: The period as a cash book
    //
    // Always open: where the card stood when the period began, what came in
    // and went out, and where it stands now. See PeriodCashBook.

    /// Nil without a card to read a balance from.
    var cashBook: PeriodCashBook? {
        guard let start = periodStartBalance else { return nil }
        var book = PeriodCashBook.build(filteredTx, start: start, convert: convertedAmount,
                                        movedFrom: OwnMoves.arrivals(into: scopeCards, cards: appVM.cards))
        book.extraFunds = periodExtraFunds
        return book
    }

    /// The window runs to today, so its last line is today's balance.
    var periodRunsToToday: Bool {
        Calendar.current.isDateInToday(effectiveRange.end) || effectiveRange.end > Date()
    }

    /// Up to two named rows a side; the rest folded into "and N more".
    func bookRows(_ rows: [NonFlowMovements.Row]) -> [(label: String, amount: Double)] {
        PeriodCashBook.shownRows(rows)
    }

    func cashBookView(_ book: PeriodCashBook) -> some View {
        let startDay = dayMonth(effectiveRange.start)
        return VStack(alignment: .leading, spacing: 6) {
            bookLine(String(format: loc("stats.book_start"), startDay), book.start, op: "")
            bookLine(loc("stats.recon_income"), book.income, op: "+")
            ForEach(Array(bookRows(book.otherIn).enumerated()), id: \.offset) { _, row in
                bookLine(row.label, row.amount, op: "+", caption: loc("stats.book_not_income"),
                         tint: AppTheme.accent)
            }
            bookLine(loc("stats.book_living"), book.living, op: "−")
            if book.debtPaid >= 0.5 {
                bookLine(loc("stats.book_debt"), book.debtPaid, op: "−",
                         caption: loc("stats.book_debt_note"), tint: AppTheme.blue)
            }
            if book.invested >= 0.5 {
                bookLine(loc("stats.book_invest"), book.invested, op: "−", tint: AppTheme.blue)
            }
            ForEach(Array(bookRows(book.otherOut).enumerated()), id: \.offset) { _, row in
                bookLine(row.label, row.amount, op: "−", caption: loc("stats.book_not_spending"))
            }
            if abs(book.ownMoves) >= 0.5 {
                ownMovesLine(book)
            }
            Rectangle().fill(AppTheme.cardMid).frame(height: 1).padding(.vertical, 2)
            // With the bill cards in it, each card's part, to set beside Home.
            bookLine(periodRunsToToday ? ScopeBalance.todayLabel(cards: scopeCards.count) : loc("stats.recon_end"),
                     book.end, op: "=", caption: periodRunsToToday ? scopeBalanceSplit : nil, total: true)

            if let line = coverLine(book) {
                Label(line, systemImage: "calendar.badge.clock")
                    .font(.system(.caption2))
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }

            // A debit account can't start below zero; a negative opening is
            // money in that was never logged. Say so, and offer the fix.
            if book.start < -0.5, let card = selectedCard, !card.isCreditCard {
                VStack(alignment: .leading, spacing: 6) {
                    Label(String(format: loc("stats.book_neg_start"), startDay), systemImage: "info.circle")
                        .font(.system(.caption2))
                        .foregroundStyle(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        HapticManager.shared.tap()
                        matchBalanceCard = card
                    } label: {
                        HStack(spacing: 3) {
                            Text(loc("stats.match_cta"))
                            Image(systemName: "chevron.right").imageScale(.small)
                        }
                        .font(.system(.caption, weight: .semibold))
                        .foregroundStyle(AppTheme.accent)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 4)
            }
        }
        .padding(12)
        .heroPanel(AppTheme.flowGround.opacity(0.46), edge: 0.09)
    }

    /// The moves between own cards, one line per other card. See OwnMoves.
    var ownMoveLines: [OwnMoves.Line] {
        OwnMoves.lines(filteredTx, scope: scopeCards, cards: appVM.cards, convert: convertedAmount)
    }

    /// "Between your own accounts", which opens into where the money came
    /// from and went — and what had come into the other card just before.
    @ViewBuilder
    func ownMovesLine(_ book: PeriodCashBook) -> some View {
        let lines = ownMoveLines
        if lines.isEmpty {
            bookLine(loc("stats.book_own_moves"), abs(book.ownMoves), op: book.ownMoves < 0 ? "−" : "+")
        } else {
            Button {
                HapticManager.shared.tap()
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { showOwnMoves.toggle() }
            } label: {
                bookLine(loc("stats.book_own_moves"), abs(book.ownMoves), op: book.ownMoves < 0 ? "−" : "+",
                         chevron: showOwnMoves)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(loc(showOwnMoves ? "stats.own_hide" : "stats.own_show"))

            if showOwnMoves {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(lines) { line in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(String(format: loc(line.incoming ? "stats.own_from" : "stats.own_to"), line.label))
                                    .font(.system(.caption2))
                                    .foregroundStyle(AppTheme.textSecondary)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                Text((line.incoming ? "+" : "−") + money(line.amount))
                                    .font(.system(.caption2, weight: .semibold))
                                    .foregroundStyle(AppTheme.textSecondary)
                                    .monospacedDigit()
                            }
                            ForEach(line.sources) { src in
                                Text(String(format: loc("stats.own_source"), src.name, money(src.amount),
                                            dayMonth(src.date)))
                                    .font(.system(.caption2))
                                    .foregroundStyle(AppTheme.accent)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(.leading, 20)
                .transition(.opacity)
            }
        }
    }

    /// When income ran out, and what paid after that — in the order it
    /// happened. Nil while income covered everything.
    func coverLine(_ book: PeriodCashBook) -> String? {
        book.coverSentence(money: money, day: dayMonth)
    }

    /// One line of the book. `value` is a magnitude; `op` carries its direction,
    /// except the opening balance, which can itself be below zero. `chevron`
    /// marks a line that opens: false closed, true open.
    func bookLine(_ label: String, _ value: Double, op: String, caption: String? = nil,
                  total: Bool = false, tint: Color? = nil, chevron: Bool? = nil) -> some View {
        let figure = (value < -0.5 ? "−" : "") + money(abs(value))
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(op)
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(AppTheme.textSecondary)
                .frame(width: 12, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(label)
                        .font(.system(.caption, weight: total ? .semibold : .regular))
                        .foregroundStyle(total ? AppTheme.textPrimary : AppTheme.textSecondary)
                        .lineLimit(2)
                    if let open = chevron {
                        Image(systemName: "chevron.down")
                            .font(.system(.caption2, weight: .semibold))
                            .foregroundStyle(AppTheme.accent)
                            .rotationEffect(.degrees(open ? 180 : 0))
                    }
                }
                if let caption {
                    Text(caption)
                        .font(.system(.caption2))
                        .foregroundStyle(AppTheme.textSecondary.opacity(0.85))
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
            }
            Spacer(minLength: 8)
            Text(figure)
                .font(.system(.caption, weight: total ? .bold : .semibold))
                .foregroundStyle(tint ?? (total ? AppTheme.textPrimary : AppTheme.textSecondary))
                .monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .combine)
    }

    /// Spending by month (or pay period), the current one in ink, opening
    /// the trends; then this week, opening the week. Plain on the page: the
    /// two cards they sat in, and the strip of four figures above them, said
    /// again what the hero and the categories say.
    var monthBars: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                HapticManager.shared.tap()
                appVM.statsPath.append(.trends)
            } label: {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(loc("stats.trends"))
                            .font(.system(.body, weight: .bold))
                            .foregroundStyle(AppTheme.textPrimary)
                        Spacer(minLength: 6)
                        // The trend buckets follow the pay cycle whenever there
                        // is a salary to anchor them, so the last bar is this
                        // PERIOD, not this month.
                        Text(loc(payCycleDay != nil ? "stats.this_period" : "stats.this_month"))
                            .font(.system(.caption))
                            .foregroundStyle(AppTheme.textSecondary)
                        Text(money(trendTotal))
                            .font(.system(.subheadline, weight: .semibold).monospacedDigit())
                            .foregroundStyle(AppTheme.textPrimary)
                            .lineLimit(1).minimumScaleFactor(0.7)
                        Image(systemName: "chevron.right")
                            .font(.system(.caption, weight: .semibold))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                    // The current one in ink, the others faint: money going out
                    // is not green.
                    MiniBars(values: trendBars.map(\.value), labels: trendBars.map(\.label),
                             tint: AppTheme.textPrimary, highlightLast: true)
                        .frame(height: 54)
                }
                .padding(.bottom, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Rectangle().fill(AppTheme.cardMid).frame(height: 1)

            Button {
                HapticManager.shared.tap()
                appVM.statsPath.append(.weekly)
            } label: {
                HStack(spacing: 6) {
                    Text(loc("stats.this_week"))
                        .font(.system(.subheadline, weight: .medium))
                        .foregroundStyle(AppTheme.textPrimary)
                    Spacer(minLength: 6)
                    Text(money(weekTotal))
                        .font(.system(.subheadline, weight: .semibold).monospacedDigit())
                        .foregroundStyle(AppTheme.textPrimary)
                    Image(systemName: "chevron.right")
                        .font(.system(.caption, weight: .semibold))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// The hairline between figures on the detail screens' strips.
    var metricDivider: some View {
        Rectangle().fill(AppTheme.cardMid.opacity(0.7)).frame(width: 1, height: 32)
    }

    // MARK: 1 · How much went out, and am I fine

    /// One sentence on where this is heading, for a period still running —
    /// for living costs, the figure held against income above. Debt paid and
    /// money put away so far are taken out of the projection, or a card
    /// payment would read as a pace of overspending.
    func paceLine(_ book: PeriodCashBook?) -> (ok: Bool, text: String)? {
        PeriodCashBook.paceSentence(projected: projectedSpend, book: book, livingFunds: livingFunds,
                                    money: money)
    }

    // MARK: 2 · Where it went

    /// Same subtype rules as the totals: transfers skipped, refunds taken off
    /// their category, income counting normal income only.
    var categoryBreakdown: [(category: TxCategory, amount: Double)] {
        var totals: [TxCategory: Double] = [:]
        let expensesTab = statsVM.selectedStatTab == .expenses
        for tx in filteredTx where tx.txSubtype != .transfer {
            let amt = abs(convertedAmount(tx))
            if expensesTab {
                if tx.txSubtype == .refund { totals[tx.category, default: 0] -= amt }
                else if tx.amount < 0 { totals[tx.category, default: 0] += amt }
            } else if tx.txSubtype == .normal && tx.amount > 0 {
                totals[tx.category, default: 0] += amt
            }
        }
        return totals.filter { $0.value > 0 }
            .map { (category: $0.key, amount: $0.value) }
            .sorted { $0.amount > $1.amount }
    }

    /// What the ring is pointing at: the period's total, or the slice the user
    /// tapped. Tapping the same slice again returns the total.
    @ViewBuilder
    func donutFigure(rows: [(category: TxCategory, amount: Double)], total: Double) -> some View {
        let picked = rows.first { $0.category.rawValue == donutSelection }
        VStack(alignment: .leading, spacing: 3) {
            Text(picked?.category.displayLabel ?? loc("stats.total"))
                .font(.system(.footnote))
                .foregroundStyle(AppTheme.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(money(picked?.amount ?? total))
                .font(.system(.title3, weight: .bold))
                .foregroundStyle(AppTheme.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.6)
            if let picked, total > 0 {
                Text("\(Int(((picked.amount / total) * 100).rounded()))%")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(Color(hex: picked.category.iconBg))
            } else {
                Text(String(format: loc("stats.categories_count"), rows.count))
                    .font(.system(.caption))
                    .foregroundStyle(AppTheme.textSecondary.opacity(0.8))
                    .lineLimit(1)
            }
        }
        .animation(.easeOut(duration: 0.18), value: donutSelection)
    }

    var categoriesCard: some View {
        let rows = categoryBreakdown
        let total = rows.reduce(0) { $0 + $1.amount }
        let shown = showAllCategories ? rows : Array(rows.prefix(Self.categoryPreview))
        return VStack(alignment: .leading, spacing: 14) {
            // Title and toggle share a row only while both fit whole. Squeezed
            // side by side, "Pemasukan" and "Pengeluaran" broke mid-word over
            // two lines; when they don't fit, the toggle gets its own row.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center) {
                    categoriesTitle.fixedSize()
                    Spacer(minLength: 8)
                    flowToggle(fill: false)
                }
                VStack(alignment: .leading, spacing: 10) {
                    categoriesTitle
                    flowToggle(fill: true)
                }
            }

            if rows.isEmpty {
                VStack(spacing: 10) {
                    Text(String(format: loc("stats.title_empty"),
                                statsVM.selectedStatTab.localizedLabel.lowercased()))
                        .font(.system(.subheadline)).foregroundStyle(AppTheme.textSecondary)
                    Button {
                        HapticManager.shared.tap()
                        NotificationCenter.default.post(name: .requestOpenAddTransaction, object: nil)
                    } label: {
                        Label(loc("home.add_first_tx"), systemImage: "plus.circle.fill")
                            .font(.system(.footnote, weight: .semibold))
                            .foregroundStyle(AppTheme.onVividFill)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(AppTheme.accentFill, in: Capsule())
                    }
                    .buttonStyle(ScaleButtonStyle())
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            } else {
                // The ring answers "how is this divided", which a ranked list
                // answers badly; the list below keeps the figures, which a ring
                // cannot give to the rupiah. Neither replaces the other.
                // The figure sits BESIDE the ring, not inside it. In the hole
                // it had to shrink to fit and still crowded the wedges, which
                // reach toward the middle by design; out here it can be read at
                // a size that suits a total, and the space was empty anyway.
                HStack(alignment: .center, spacing: 14) {
                    SpendDonut(slices: rows.map {
                                   DonutSlice(id: $0.category.rawValue,
                                              label: $0.category.displayLabel,
                                              amount: $0.amount,
                                              color: Color(hex: $0.category.iconBg),
                                              // The share sits on the pale wedge,
                                              // never on the saturated rim.
                                              labelColor: AppTheme.textPrimary)
                               },
                               total: total,
                               selectedID: $donutSelection)
                        // 160 checked against a mock at the real card width:
                        // the total reads at full size beside it, which it did
                        // not at 176.
                        .frame(width: 160, height: 160)

                    donutFigure(rows: rows, total: total)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.bottom, 4)

                VStack(spacing: 14) {
                    ForEach(Array(shown.enumerated()), id: \.element.category) { i, row in
                        categoryRow(row.category, amount: row.amount,
                                    share: total > 0 ? row.amount / total : 0, index: i)
                    }
                }
                if rows.count > Self.categoryPreview {
                    Button {
                        HapticManager.shared.tap()
                        withAnimation(.spring(response: 0.35)) { showAllCategories.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Text(showAllCategories
                                 ? loc("stats.show_less")
                                 : String(format: loc("stats.show_all_categories"), rows.count))
                            Image(systemName: showAllCategories ? "chevron.up" : "chevron.down")
                                .imageScale(.small)
                        }
                        .font(.system(.footnote, weight: .semibold))
                        .foregroundStyle(AppTheme.textSecondary)
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                }
            }

            nonFlowSection
        }
    }

    /// Transfers for the current tab, shown beside the breakdown and never
    /// added to it (see NonFlowMovements).
    var nonFlowRows: [NonFlowMovements.Row] {
        NonFlowMovements.rows(filteredTx, incoming: statsVM.selectedStatTab != .expenses,
                              amount: { convertedAmount($0) })
    }

    @ViewBuilder
    var nonFlowSection: some View {
        let rows = nonFlowRows
        if !rows.isEmpty {
            let incoming = statsVM.selectedStatTab != .expenses
            VStack(alignment: .leading, spacing: 10) {
                Rectangle().fill(AppTheme.cardMid.opacity(0.7)).frame(height: 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(loc(incoming ? "stats.nonflow.in_title" : "stats.nonflow.out_title"))
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(loc(incoming ? "stats.nonflow.in_sub" : "stats.nonflow.out_sub"))
                        .font(.system(.caption2))
                        .foregroundStyle(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(rows.prefix(5), id: \.label) { r in
                    HStack(spacing: 12) {
                        Image(systemName: incoming ? "arrow.down.left" : "arrow.up.right")
                            .font(.system(.caption, weight: .bold))
                            .foregroundStyle(AppTheme.textSecondary)
                            .frame(width: 24)
                        Text(r.label)
                            .font(.system(.subheadline))
                            .foregroundStyle(AppTheme.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(money(r.amount))
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundStyle(AppTheme.textSecondary)
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                }
                if rows.count > 5 {
                    Text(String(format: loc("stats.nonflow.more"), rows.count - 5))
                        .font(.system(.caption2))
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }
            .padding(.top, 4)
        }
    }

    /// Money out / money in, as two small pills.
    private var categoriesTitle: some View {
        Text(loc(statsVM.selectedStatTab == .expenses ? "stats.where_title" : "stats.where_income_title"))
            .font(.system(.body, weight: .bold))
            .foregroundStyle(AppTheme.textPrimary)
    }

    /// `fill`: segments share the full width, for when it sits on its own row.
    func flowToggle(fill: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(StatTab.allCases, id: \.self) { tab in
                let on = statsVM.selectedStatTab == tab
                Button {
                    guard !on else { return }
                    withAnimation(.spring(response: 0.3)) { statsVM.switchTab(tab) }
                } label: {
                    // The choice in ink. It was the page's ground on the
                    // track, two greys a few steps apart, and in the light
                    // theme the chosen side could not be told from the other.
                    // Ink holds in both themes; green would say money in.
                    Text(tab.localizedLabel)
                        .font(.system(.caption, weight: .semibold))
                        .foregroundStyle(on ? AppTheme.cardDark : AppTheme.textSecondary)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .frame(maxWidth: fill ? .infinity : nil)
                        .background(on ? AppTheme.textPrimary : Color.clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(AppTheme.cardMid.opacity(0.7), in: Capsule())
    }

    // One hue stepped by rank was tried here and dropped: the ring became a
    // scale of greens while the rows beside it kept their category colours, so
    // nothing tied a slice to its figure. The category colour is the app's
    // shorthand for "Food" on every screen, and the chart uses it too.

    func categoryRow(_ cat: TxCategory, amount: Double, share: Double, index: Int
) -> some View {
        let hue = Color(hex: cat.iconBg)
        return HStack(spacing: 12) {
            // The glyph in its category's colour, no disc behind it.
            Image(systemName: cat.icon)
                .font(.system(.body, weight: .semibold))
                .foregroundStyle(hue)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(cat.displayLabel)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(money(amount))
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
                HStack(spacing: 8) {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(AppTheme.cardMid.opacity(0.8))
                            Capsule().fill(hue)
                                .frame(width: max(g.size.width * CGFloat(share) * statsVM.chartProgress, 4))
                                .animation(.spring(response: 0.7, dampingFraction: 0.85)
                                    .delay(Double(index) * 0.05), value: statsVM.chartProgress)
                        }
                    }
                    .frame(height: 6)
                    Text("\(Int((share * 100).rounded()))%")
                        .font(.system(.caption, weight: .medium))
                        .foregroundStyle(AppTheme.textSecondary)
                        .frame(width: 38, alignment: .trailing)
                }
            }
        }
    }

    // MARK: 3 · Worth knowing

    /// At most three plain sentences. The pace already sits in the summary, so
    /// it is not repeated here.
    var noteRows: [(icon: String, tint: Color, title: String, detail: String)] {
        var out: [(icon: String, tint: Color, title: String, detail: String)] = []
        if weeklyAverage > 0 {
            out.append(("cup.and.saucer.fill", AppTheme.purple,
                        String(format: loc("stats.weekly_line"), money(weeklyAverage)),
                        loc("stats.weekly_line_sub")))
        }
        for row in patternRows where row.icon != "chart.line.uptrend.xyaxis" {
            out.append((row.icon, row.tint, row.title, row.detail))
        }
        return Array(out.prefix(3))
    }

    @ViewBuilder
    var notesCard: some View {
        let rows = noteRows
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(loc("stats.notes_title"))
                    .font(.system(.body, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                if premiumMgr.canAccess(.smartBudget) {
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                            if i > 0 {
                                Rectangle().fill(AppTheme.cardMid.opacity(0.7)).frame(height: 1).padding(.leading, 40)
                            }
                            noteRow(row.icon, row.tint, row.title, row.detail)
                        }
                    }
                } else {
                    lockedNotes(rows)
                }
            }
        }
    }

    func noteRow(_ icon: String, _ tint: Color, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // The glyph in its colour, nothing behind it.
            Image(systemName: icon)
                .font(.system(.body, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(.system(.caption))
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
    }

    /// The shape of the notes with the words hidden, and one way to open them.
    func lockedNotes(_ rows: [(icon: String, tint: Color, title: String, detail: String)]) -> some View {
        Button {
            HapticManager.shared.tap()
            NotificationCenter.default.post(name: .requestOpenPaywall, object: nil)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                VStack(spacing: 0) {
                    ForEach(Array(rows.prefix(2).enumerated()), id: \.offset) { _, row in
                        noteRow(row.icon, row.tint, row.title, row.detail)
                    }
                }
                .redacted(reason: .placeholder)
                .blur(radius: 3)
                .accessibilityHidden(true)
                HStack(spacing: 6) {
                    Image(systemName: "crown.fill")
                    Text(loc("stats.insights_locked"))
                }
                .font(.system(.footnote, weight: .bold))
                .foregroundStyle(PremiumPlan.royal.color)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: 4 · The working, one tap away

    var detailLink: some View {
        Button {
            HapticManager.shared.tap()
            appVM.statsPath.append(.analysis)
        } label: {
            PlanRowLabel(icon: "doc.text.magnifyingglass", tint: AppTheme.blue,
                         title: loc("stats.detail_link"),
                         status: loc("stats.detail_link_sub"),
                         lockedPlan: nil)
                .overlay(alignment: .top) { Rectangle().fill(AppTheme.cardMid).frame(height: 1) }
        }
        .buttonStyle(ScaleButtonStyle())
    }
}

extension View {
    /// A panel on the hero's field: a tinted fill and a hairline that
    /// catches the light, as the web's frosted boxes. The shared report
    /// draws its panels the same way.
    func heroPanel(_ fill: Color, edge: Double = 0.06) -> some View {
        background(fill, in: RoundedRectangle(cornerRadius: AppRadius.md))
            .overlay(RoundedRectangle(cornerRadius: AppRadius.md).stroke(Color.white.opacity(edge), lineWidth: 1))
    }
}
