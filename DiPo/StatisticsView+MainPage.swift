import SwiftUI
import SwiftData

// Part of StatisticsView, moved out of StatisticsView.swift unchanged. The main page: headline, where it went, worth knowing.

extension StatisticsView {
    // MARK: Main page

    var mainPage: some View {
        ZStack {
            AppTheme.bg.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    spendHero
                    metricStrip
                    dualCards
                    categoriesCard
                    notesCard
                    detailLink
                    Spacer(minLength: 110)
                }
                .padding(.horizontal, 22)
                .padding(.top, 20)
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
                }
                Spacer()
                Button {
                    HapticManager.shared.tap()
                    showExportSheet = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(.body, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .frame(width: 44, height: 44)
                        .background(AppTheme.cardDark, in: Circle())
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
                .padding(.horizontal, 13).padding(.vertical, 8)
                .background(AppTheme.cardDark, in: Capsule())
            }
        }
    }

    // MARK: 0 · The headline, at a glance
    //
    // A hero figure with the period's cash book under it, its progress, a strip
    // of the four numbers people check daily, and two tiles that show the shape
    // of the week and of the months. The working stays one tap away in Full
    // analysis.

    var spendHero: some View {
        let left = leftToSpend
        let book = cashBook
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(heroLabel(left))
                    .font(.system(.footnote, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary)
                // Signed, never clamped. "Rp 0" for a period Rp 273.500 over
                // its income hid the one thing the screen should say.
                Text(heroFigure(left))
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle((left ?? 0) < -0.5 ? AppTheme.red : AppTheme.textPrimary)
                    .contentTransition(.numericText())
                    .minimumScaleFactor(0.5).lineLimit(1)
            }

            if let book { cashBookView(book, left: left) }

            if filteredIncome > 0 {
                VStack(alignment: .leading, spacing: 8) {
                    // The existing gauge, not a plain bar: it carries the tick for
                    // how much of the period has elapsed, so spending ahead of the
                    // calendar is visible rather than merely counted.
                    SpendGauge(fraction: spentRatio,
                               timeMarker: periodProgress.map { Double($0.elapsed) / Double($0.total) })

                    HStack(spacing: 8) {
                        Text(String(format: loc("stats.pct_of_income"), incomeUsedPct))
                            .font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                            .lineLimit(1).minimumScaleFactor(0.7)
                        Spacer(minLength: 4)
                        if let c = expenseChange, abs(c) >= 1 {
                            HStack(spacing: 3) {
                                Image(systemName: c >= 0 ? "arrow.up.right" : "arrow.down.right")
                                    .font(.system(.caption2, weight: .bold))
                                // Says what it is compared with: "60%" alone
                                // read as anything.
                                Text(String(format: loc("stats.vs_last_period"),
                                            String(format: "%.0f%%", abs(c))))
                                    .font(.system(.caption2, weight: .bold))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(c >= 0 ? AppTheme.red : AppTheme.accent)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background((c >= 0 ? AppTheme.red : AppTheme.accent).opacity(0.15), in: Capsule())
                        }
                    }
                }
            }

            // Where this period is heading, in one sentence.
            if let line = paceLine(book) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: line.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(.subheadline))
                        .foregroundStyle(line.ok ? AppTheme.accent : AppTheme.orange)
                    Text(line.text)
                        .font(.system(.footnote, weight: .medium))
                        .foregroundStyle(AppTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background((line.ok ? AppTheme.accent : AppTheme.orange).opacity(0.10),
                            in: RoundedRectangle(cornerRadius: AppRadius.md))
            } else if filteredIncome <= 0 {
                Label(loc("stats.no_income_hint"), systemImage: "info.circle")
                    .font(.system(.caption))
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: AppRadius.xl).fill(AppTheme.cardDark)
                .overlay {
                    LinearGradient(colors: [AppTheme.accent.opacity(0.20),
                                            AppTheme.blue.opacity(0.06), .clear],
                                   startPoint: .topTrailing, endPoint: .bottomLeading)
                }
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.xl))
        }
    }

    func heroLabel(_ left: Double?) -> String {
        guard let left else { return loc("stats.expenses") }
        return loc(left < -0.5 ? "stats.net_over" : "stats.net_left")
    }

    func heroFigure(_ left: Double?) -> String {
        guard let left else { return money(filteredExpenses) }
        return left < -0.5 ? "−" + money(-left) : money(max(left, 0))
    }

    /// Share of income spent, as on Home: past 100 when spending passes
    /// income, and held below 100 until the income is actually all gone.
    var incomeUsedPct: Int {
        guard filteredIncome > 0 else { return 0 }
        let ratio = filteredExpenses / filteredIncome
        let pct = Int((ratio * 100).rounded())
        return ratio < 1 ? min(pct, 99) : max(pct, 100)
    }

    // MARK: The period as a cash book
    //
    // Always open, under the hero figure: where the card stood when the period
    // began, what came in and went out, and where it stands now. The old hero
    // put "Left to spend Rp 0" beside a Rp 4 jt balance and hid the arithmetic
    // that joins them behind a chevron; with a loan repaid that is not income,
    // the two read as a mistake. See PeriodCashBook.

    /// Nil without a card to read a balance from.
    var cashBook: PeriodCashBook? {
        guard let start = periodStartBalance else { return nil }
        return PeriodCashBook.build(filteredTx, start: start, convert: convertedAmount)
    }

    /// The window runs to today, so its last line is today's balance.
    var periodRunsToToday: Bool {
        Calendar.current.isDateInToday(effectiveRange.end) || effectiveRange.end > Date()
    }

    /// Up to two named rows a side; the rest folded into "and N more".
    func bookRows(_ rows: [NonFlowMovements.Row]) -> [(label: String, amount: Double)] {
        let shown = rows.count > 3 ? Array(rows.prefix(2)) : rows
        var out: [(label: String, amount: Double)] = shown.map { (label: $0.label, amount: $0.amount) }
        if rows.count > 3 {
            let rest = rows.dropFirst(2)
            out.append((label: String(format: loc("stats.nonflow.more"), rest.count),
                        amount: rest.reduce(0.0) { $0 + $1.amount }))
        }
        return out
    }

    func cashBookView(_ book: PeriodCashBook, left: Double?) -> some View {
        let fmt = DateFormatter()
        fmt.locale = LanguageManager.shared.currentLocale
        fmt.setLocalizedDateFormatFromTemplate("d MMM")
        return VStack(alignment: .leading, spacing: 6) {
            bookLine(String(format: loc("stats.book_start"), fmt.string(from: effectiveRange.start)),
                     book.start, op: "")
            bookLine(loc("stats.recon_income"), book.income, op: "+")
            ForEach(Array(bookRows(book.otherIn).enumerated()), id: \.offset) { _, row in
                bookLine(row.label, row.amount, op: "+", caption: loc("stats.book_not_income"),
                         tint: AppTheme.accent)
            }
            bookLine(loc("stats.recon_spent"), book.spent, op: "−")
            ForEach(Array(bookRows(book.otherOut).enumerated()), id: \.offset) { _, row in
                bookLine(row.label, row.amount, op: "−", caption: loc("stats.book_not_spending"))
            }
            if abs(book.ownMoves) >= 0.5 {
                bookLine(loc("stats.book_own_moves"), abs(book.ownMoves), op: book.ownMoves < 0 ? "−" : "+")
            }
            Rectangle().fill(AppTheme.cardMid).frame(height: 1).padding(.vertical, 2)
            bookLine(loc(periodRunsToToday ? "stats.card_balance_now" : "stats.recon_end"),
                     book.end, op: "=", total: true)

            if let note = bookNote(book, left: left) {
                Text(note)
                    .font(.system(.caption))
                    .foregroundStyle(AppTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }
        }
        .padding(12)
        .background(AppTheme.bg.opacity(0.55), in: RoundedRectangle(cornerRadius: AppRadius.md))
    }

    /// One line of the book. `value` is a magnitude; `op` carries its direction,
    /// except the opening balance, which can itself be below zero.
    func bookLine(_ label: String, _ value: Double, op: String, caption: String? = nil,
                  total: Bool = false, tint: Color? = nil) -> some View {
        let figure = (value < -0.5 ? "−" : "") + money(abs(value))
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(op)
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(AppTheme.textSecondary)
                .frame(width: 12, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(.caption, weight: total ? .semibold : .regular))
                    .foregroundStyle(total ? AppTheme.textPrimary : AppTheme.textSecondary)
                    .lineLimit(2)
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

    /// One sentence when spending passed income: what kept the balance up.
    func bookNote(_ book: PeriodCashBook, left: Double?) -> String? {
        guard let left, left < -0.5, let why = book.overspend(deficit: -left) else { return nil }
        switch why {
        case .coveredBy(let label, let amount):
            return String(format: loc("stats.book_over_in"), money(-left), money(book.end), label, money(amount))
        case .savings:
            return String(format: loc("stats.book_over_saved"), money(-left))
        case .plain:
            return String(format: loc("stats.book_over_plain"), money(-left))
        }
    }

    var metricStrip: some View {
        let top = topCategories.first
        let usedText: String = filteredIncome > 0 ? "\(incomeUsedPct)%" : "—"
        return HStack(spacing: 0) {
            metricCell("chart.pie.fill", AppTheme.accent,
                       usedText,
                       loc("stats.metric_of_income"))
            metricDivider
            metricCell("sun.max.fill", AppTheme.amber, money(todaySpend), loc("common.today"))
            metricDivider
            // The median day of day-to-day spending — not an allowance. "per
            // day" read as how much may be spent each day.
            metricCell("scope", AppTheme.blue, money(typicalDailySpend), loc("stats.metric_typical_day"))
            metricDivider
            // Named as the top category, or "Bills" read as bills still due.
            metricCell("tag.fill", top?.category.color ?? AppTheme.purple,
                       money(top?.amount ?? 0),
                       top.map { String(format: loc("stats.metric_top_named"), $0.category.displayLabel) }
                           ?? loc("stats.metric_top"))
        }
        .padding(.vertical, 12)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
    }

    func metricCell(_ icon: String, _ tint: Color, _ value: String, _ label: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon).font(.system(.caption, weight: .bold)).foregroundStyle(tint)
            Text(value).font(.system(.subheadline, weight: .bold))
                .foregroundStyle(AppTheme.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.5)
            Text(label).font(.system(size: 10, weight: .medium))
                .foregroundStyle(AppTheme.textSecondary)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 4)
    }

    var metricDivider: some View {
        Rectangle().fill(AppTheme.cardMid.opacity(0.7)).frame(width: 1, height: 32)
    }

    var dualCards: some View {
        HStack(spacing: 12) {
            miniStatCard(loc("stats.weekly"), loc("stats.this_week"), weekTotal,
                         "chart.bar.fill", AppTheme.blue, weekBars,
                         highlightLast: false, route: .weekly)
            // The trend buckets follow the pay cycle whenever there is a salary
            // to anchor them, so the last bar is this PERIOD, not this month.
            miniStatCard(loc("stats.trends"), loc(payCycleDay != nil ? "stats.this_period" : "stats.this_month"),
                         trendTotal,
                         "chart.line.uptrend.xyaxis", AppTheme.accent, trendBars,
                         highlightLast: true, route: .trends)
        }
    }

    func miniStatCard(_ title: String, _ subtitle: String, _ value: Double,
                              _ icon: String, _ tint: Color,
                              _ bars: [(label: String, value: Double)],
                              highlightLast: Bool, route: StatsRoute) -> some View {
        Button {
            HapticManager.shared.tap()
            appVM.statsPath.append(route)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: icon).font(.system(.caption, weight: .bold)).foregroundStyle(tint)
                    Text(title).font(.system(.subheadline, weight: .bold))
                        .foregroundStyle(AppTheme.textPrimary).lineLimit(1)
                    Spacer(minLength: 2)
                    Image(systemName: "chevron.right").font(.system(.caption2, weight: .semibold))
                        .foregroundStyle(AppTheme.textSecondary.opacity(0.6))
                }
                Text(subtitle).font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                Text(money(value)).font(.system(.title3, weight: .bold))
                    .foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.5)
                    .padding(.bottom, 2)
                MiniBars(values: bars.map(\.value), labels: bars.map(\.label),
                         tint: tint, highlightLast: highlightLast)
                    .frame(height: 54)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
        }
        .buttonStyle(ScaleButtonStyle())
    }

    // MARK: 1 · How much went out, and am I fine

    var expenseChange: Double? {
        guard let prev = previousPeriodExpenses, prev > 0 else { return nil }
        return (filteredExpenses - prev) / prev * 100
    }

    /// One sentence on where this is heading, for a period still running.
    /// `book` is the hero's own, passed in rather than rebuilt.
    func paceLine(_ book: PeriodCashBook?) -> (ok: Bool, text: String)? {
        guard let projected = projectedSpend, filteredIncome > 0 else { return nil }
        var text = projected <= filteredIncome
            ? String(format: loc("stats.pace_safe"), money(projected))
            : String(format: loc("stats.pace_over"), money(projected), money(projected - filteredIncome))
        // What that leaves on the card — the question behind the pace. Today's
        // balance less the spending still to come; money in or out that is not
        // income or spending can't be foreseen and isn't guessed at.
        if let book, let p = periodProgress,
           let last = Calendar.current.date(byAdding: .day, value: p.total - 1,
                                            to: Calendar.current.startOfDay(for: effectiveRange.start)) {
            let fmt = DateFormatter()
            fmt.locale = LanguageManager.shared.currentLocale
            fmt.setLocalizedDateFormatFromTemplate("d MMM")
            let endBalance = book.end - max(projected - filteredExpenses, 0)
            text += " " + String(format: loc("stats.pace_balance"),
                                 (endBalance < -0.5 ? "−" : "") + money(abs(endBalance)),
                                 fmt.string(from: last))
        }
        return (projected <= filteredIncome, text)
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
        .padding(16)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.xl))
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
                            .frame(width: 36, height: 36)
                            .background(AppTheme.cardMid, in: Circle())
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
                    Text(tab.localizedLabel)
                        .font(.system(.caption, weight: .semibold))
                        .foregroundStyle(on ? AppTheme.textPrimary : AppTheme.textSecondary)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .frame(maxWidth: fill ? .infinity : nil)
                        .background(on ? AppTheme.bg : Color.clear, in: Capsule())
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
            Image(systemName: cat.icon)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(hue, in: Circle())
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
                                Rectangle().fill(AppTheme.cardMid.opacity(0.7)).frame(height: 1).padding(.leading, 48)
                            }
                            noteRow(row.icon, row.tint, row.title, row.detail)
                        }
                    }
                } else {
                    lockedNotes(rows)
                }
            }
            .padding(16)
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.xl))
        }
    }

    func noteRow(_ icon: String, _ tint: Color, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(.footnote, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: AppRadius.sm))
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
                .background(PremiumPlan.royal.color.opacity(0.12), in: RoundedRectangle(cornerRadius: AppRadius.md))
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
                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
        }
        .buttonStyle(ScaleButtonStyle())
    }
}
