import SwiftUI
import SwiftData

// Part of StatisticsView, moved out of StatisticsView.swift unchanged. The pages one tap away: weekly, trends, one cycle, full analysis.

extension StatisticsView {
    // MARK: Weekly · its own page
    //
    // The tile answers "how much this week"; this page answers "which days, and
    // is that unusual" — the same figures, opened up, day by day.

    var weekRangeLabel: String {
        let cal = weekCalendar
        guard let w = cal.dateInterval(of: .weekOfYear, for: Date()) else { return "" }
        let df = DateFormatter()
        df.locale = LanguageManager.shared.currentLocale
        df.dateFormat = DateFormatter.dateFormat(fromTemplate: "dMMM", options: 0,
                                                 locale: LanguageManager.shared.currentLocale)
        let last = cal.safeDate(byAdding: .day, value: -1, to: w.end)
        return "\(df.string(from: w.start)) – \(df.string(from: last))"
    }

    var weeklyDetail: some View {
        let split = categorySplit(weekSpendTx)
        let keep = matches(weekFilter, tailCats: split.tailCats)
        let days = weekDays(keep)
        let total = days.reduce(0.0) { $0 + $1.amount }
        let prev = previousWeekTotal(keep)
        let elapsed = days.filter { !$0.isFuture }
        let change: Double? = prev > 0 ? (total - prev) / prev * 100 : nil
        let avg = elapsed.isEmpty ? 0 : total / Double(elapsed.count)
        let busiest = days.max { $0.amount < $1.amount }
        // A day with no spending only counts as one if the day is KNOWN:
        // either it carries rows, or the user answered DiPo's check-in. Counting
        // every empty day here was the screen congratulating the user for days
        // it knew nothing about — the week someone forgot to open the app scored
        // best of all.
        let loggedDays = DailyCheckIn.loggedDays(selectedCard?.transactions ?? [])
        let answeredDays = Set(checkIns.map(\.dayKey))
        let known = elapsed.filter {
            DailyCheckIn.knowledge(of: $0.date, logged: loggedDays, answered: answeredDays) != .unknown
        }
        let quietCount = known.filter { $0.amount <= 0 }.count
        let uncheckedCount = elapsed.count - known.count
        let shownCount = weekSpendTx.filter(keep).count

        return ZStack {
            AppTheme.bg.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    categoryFilterBar(split, selection: $weekFilter,
                                      total: total, count: shownCount)

                    statHero(title: loc("stats.this_week"), subtitle: weekRangeLabel,
                             value: total, tint: AppTheme.blue,
                             change: change, changeCaption: loc("stats.vs_last_week"),
                             previous: prev)

                    // Days inside one week are a continuous story; bars stay
                    // on Trends, where each column is a period of its own.
                    SpendLineChart(points: days.enumerated().map { i, d in
                                       SpendLinePoint(id: i, label: d.short,
                                                      value: d.amount, isFuture: d.isFuture)
                                   },
                                   tint: AppTheme.blue,
                                   format: { money($0) })
                        .padding(16)
                        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.xl))

                    HStack(spacing: 10) {
                        factTile(loc("stats.daily_avg"), money(avg), AppTheme.blue)
                        factTile(loc("stats.busiest_day"),
                                 (busiest?.amount ?? 0) > 0 ? (busiest?.full ?? "—") : "—",
                                 AppTheme.orange)
                        factTile(loc("stats.no_spend_days"), "\(quietCount)", AppTheme.accent)
                    }

                    // Said out loud rather than folded into the tile above it:
                    // the figure is smaller than the week because some days have
                    // no answer, and a reader deserves to know which.
                    if uncheckedCount > 0 {
                        Text(String(format: loc("stats.unchecked_days"), uncheckedCount))
                            .font(.system(.caption2))
                            .foregroundStyle(AppTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 4)
                    }

                    VStack(spacing: 0) {
                        ForEach(Array(days.enumerated()), id: \.element.id) { i, d in
                            dayRow(d, keep: keep)
                            if i < days.count - 1 {
                                Rectangle().fill(AppTheme.cardMid.opacity(0.6)).frame(height: 1)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.xl))

                    Spacer(minLength: 100)
                }
                .padding(.horizontal, 22).padding(.top, 8)
            }
        }
        .navigationTitle(loc("stats.weekly"))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// One day of the week: tap it to open the transactions behind its figure.
    @ViewBuilder
    func dayRow(_ d: WeekDay, keep: (TxRecord) -> Bool) -> some View {
        let rows = expandedDay == d.date ? spendTx(on: d.date).filter(keep) : []
        let openable = !d.isFuture && d.txCount > 0
        VStack(spacing: 0) {
            Button {
                guard openable else { return }
                HapticManager.shared.tap()
                withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                    expandedDay = (expandedDay == d.date) ? nil : d.date
                }
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(d.full)
                                .font(.system(.subheadline, weight: d.isToday ? .bold : .medium))
                                .foregroundStyle(AppTheme.textPrimary)
                            if d.isToday {
                                Text(loc("common.today"))
                                    .font(.system(.caption2, weight: .bold))
                                    .foregroundStyle(AppTheme.blue)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(AppTheme.blue.opacity(0.15), in: Capsule())
                            }
                        }
                        Text(d.isFuture ? loc("stats.day_ahead")
                                        : String(format: loc("stats.tx_count"), d.txCount))
                            .font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
                    }
                    Spacer(minLength: 8)
                    Text(d.isFuture ? "—" : money(d.amount))
                        .font(.system(.subheadline, weight: .bold))
                        .foregroundStyle(d.amount > 0 ? AppTheme.textPrimary : AppTheme.textSecondary)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    // Only days with something to show carry the affordance.
                    Image(systemName: "chevron.down")
                        .font(.system(.caption2, weight: .bold))
                        .foregroundStyle(AppTheme.textSecondary.opacity(0.7))
                        .rotationEffect(.degrees(expandedDay == d.date ? 180 : 0))
                        .opacity(openable ? 1 : 0)
                }
                .padding(.vertical, 13)
                .contentShape(Rectangle())
                .opacity(d.isFuture ? 0.5 : 1)
            }
            .buttonStyle(.plain)
            .disabled(!openable)

            if !rows.isEmpty {
                VStack(spacing: 10) {
                    ForEach(rows) { tx in
                        TxRow(tx: tx, sourceCard: selectedCard,
                              showCard: false, animateEntrance: false)
                    }
                }
                .padding(.vertical, 12)
                .padding(.leading, 6)
            }
        }
    }

    // MARK: Trends · its own page

    var trendsDetail: some View {
        let points = netWorthTrend
        let done = points.filter { !$0.isRunning }
        let avg = done.isEmpty ? 0 : done.reduce(0.0) { $0 + $1.expense } / Double(done.count)
        let highest = done.max { $0.expense < $1.expense }
        let lowest = done.min { $0.expense < $1.expense }
        let prev = points.count >= 2 ? points[points.count - 2].expense : 0
        let change: Double? = prev > 0 ? (trendTotal - prev) / prev * 100 : nil

        return ZStack {
            AppTheme.bg.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    statHero(title: points.last?.label ?? loc("stats.this_month"),
                             subtitle: loc(payCycleDay != nil ? "stats.trend_by_cycle" : "stats.trend_by_month"),
                             value: trendTotal, tint: AppTheme.accent,
                             change: change, changeCaption: loc("stats.vs_prev_period"),
                             previous: prev)

                    // Columns said "this one is tall". A line says what shape
                    // the last six periods make, with the one you are living in
                    // picked out of it.
                    TrendLineChart(points: points.enumerated().map { i, p in
                                       TrendPoint(id: i,
                                                  label: String(p.label.prefix(3)),
                                                  rangeLabel: cycleRangeLabel(p),
                                                  value: p.expense)
                                   },
                                   tint: AppTheme.accent,
                                   format: { money($0) })
                        .padding(16)
                        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.xl))

                    HStack(spacing: 10) {
                        factTile(loc("stats.trend_avg"), money(avg), AppTheme.accent)
                        factTile(loc("stats.trend_highest"), highest.map { money($0.expense) } ?? "—", AppTheme.orange)
                        factTile(loc("stats.trend_lowest"), lowest.map { money($0.expense) } ?? "—", AppTheme.blue)
                    }

                    VStack(spacing: 10) {
                        ForEach(points.reversed()) { p in
                            Button {
                                HapticManager.shared.tap()
                                appVM.statsPath.append(.cycle(start: p.start, end: p.end, label: p.label))
                            } label: {
                                VStack(spacing: 10) {
                                    HStack {
                                        HStack(spacing: 6) {
                                            Text(p.label)
                                                .font(.system(.subheadline, weight: .bold))
                                                .foregroundStyle(AppTheme.textPrimary)
                                            if p.isRunning {
                                                Text(loc("stats.trend_running"))
                                                    .font(.system(.caption2, weight: .bold))
                                                    .foregroundStyle(AppTheme.orange)
                                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                                    .background(AppTheme.orange.opacity(0.15), in: Capsule())
                                            }
                                        }
                                        Spacer()
                                        Text(String(format: loc("stats.tx_count"), p.txCount))
                                            .font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
                                        Image(systemName: "chevron.right")
                                            .font(.system(.caption2, weight: .semibold))
                                            .foregroundStyle(AppTheme.textSecondary.opacity(0.6))
                                    }
                                    HStack(spacing: 0) {
                                        trendFigure(loc("stats.income"), p.income, AppTheme.accent)
                                        metricDivider
                                        trendFigure(loc("stats.expenses"), p.expense, AppTheme.red)
                                        metricDivider
                                        trendFigure(loc("stats.net"), p.net,
                                                    p.net >= 0 ? AppTheme.accent : AppTheme.red)
                                    }
                                }
                                .padding(14)
                                .contentShape(Rectangle())
                                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
                            }
                            .buttonStyle(ScaleButtonStyle())
                        }
                    }

                    Spacer(minLength: 100)
                }
                .padding(.horizontal, 22).padding(.top, 8)
            }
        }
        .navigationTitle(loc("stats.trends"))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: One cycle, opened up
    //
    // A bar on the Trends chart is a conclusion; this is the spending it was
    // drawn from, grouped by day. Built from the same rules as every other
    // figure on the screen so the days add up to the cycle.

    func rangeLabel(_ start: Date, _ end: Date) -> String {
        let df = DateFormatter()
        df.locale = LanguageManager.shared.currentLocale
        df.dateFormat = DateFormatter.dateFormat(fromTemplate: "dMMM", options: 0,
                                                 locale: LanguageManager.shared.currentLocale)
        // Half-open window: the last day covered is the day before it ends.
        let last = Calendar.current.safeDate(byAdding: .day, value: -1, to: end)
        return "\(df.string(from: start)) – \(df.string(from: last))"
    }

    func dayLabel(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return loc("common.today") }
        if cal.isDateInYesterday(day) { return loc("common.yesterday") }
        return DateFormatterCache.template("EEEEdMMM").string(from: day)
    }

    func cycleDetail(start: Date, end: Date, label: String) -> some View {
        let txs = (selectedCard?.transactions ?? []).filter { $0.date >= start && $0.date < end }
        let income = txs.filter { $0.amount > 0 && $0.txSubtype == .normal }
            .reduce(0.0) { $0 + convertedAmount($1) }
        let expense = expenseSum(txs)
        let spend = txs.filter { $0.txSubtype != .transfer && ($0.amount < 0 || $0.txSubtype == .refund) }
        let split = categorySplit(spend)
        let shown = spend.filter(matches(cycleFilter, tailCats: split.tailCats))
        let groups = Dictionary(grouping: shown) { Calendar.current.startOfDay(for: $0.date) }
            .map { (day: $0.key, rows: $0.value.sorted { $0.date > $1.date }) }
            .sorted { $0.day > $1.day }

        return ZStack {
            AppTheme.bg.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    categoryFilterBar(split, selection: $cycleFilter,
                                      total: expenseSum(shown), count: shown.count)

                    VStack(spacing: 12) {
                        VStack(spacing: 2) {
                            Text(label).font(.system(.subheadline, weight: .bold))
                                .foregroundStyle(AppTheme.textPrimary)
                            Text(rangeLabel(start, end))
                                .font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                        }
                        Text(money(expense))
                            .font(.system(size: 34, weight: .bold))
                            .foregroundStyle(AppTheme.textPrimary)
                            .lineLimit(1).minimumScaleFactor(0.5)
                        HStack(spacing: 0) {
                            trendFigure(loc("stats.income"), income, AppTheme.accent)
                            metricDivider
                            trendFigure(loc("stats.expenses"), expense, AppTheme.red)
                            metricDivider
                            trendFigure(loc("stats.net"), income - expense,
                                        income - expense >= 0 ? AppTheme.accent : AppTheme.red)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(18)
                    .background {
                        RoundedRectangle(cornerRadius: AppRadius.xl).fill(AppTheme.cardDark)
                            .overlay {
                                LinearGradient(colors: [AppTheme.accent.opacity(0.18),
                                                        AppTheme.accent.opacity(0.04), .clear],
                                               startPoint: .topTrailing, endPoint: .bottomLeading)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: AppRadius.xl))
                    }

                    if groups.isEmpty {
                        Text(loc(cycleFilter == .all ? "stats.cycle_empty" : "stats.cycle_empty_cat"))
                            .font(.system(.footnote)).foregroundStyle(AppTheme.textSecondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 28)
                            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.xl))
                    } else {
                        ForEach(groups, id: \.day) { g in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(dayLabel(g.day))
                                        .font(.system(.footnote, weight: .semibold))
                                        .foregroundStyle(AppTheme.textSecondary)
                                    Spacer()
                                    Text(money(expenseSum(g.rows)))
                                        .font(.system(.caption, weight: .bold))
                                        .foregroundStyle(AppTheme.textSecondary)
                                }
                                VStack(spacing: 10) {
                                    ForEach(g.rows) { tx in
                                        TxRow(tx: tx, sourceCard: selectedCard,
                                              showCard: false, animateEntrance: false)
                                    }
                                }
                                .padding(14)
                                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
                            }
                        }
                    }

                    Spacer(minLength: 100)
                }
                .padding(.horizontal, 22).padding(.top, 8)
            }
        }
        .navigationTitle(label)
        .navigationBarTitleDisplayMode(.inline)
        // Keyed to the cycle, not to appearing: opening a different cycle starts
        // unfiltered, but coming back from a transaction sheet keeps your filter.
        .task(id: label) { cycleFilter = .all }
    }

    /// The categories present in a slice, biggest first, split into the four
    /// shown as chips and the tail that hides behind "Others".
    struct CategorySplit {
        var top: [(cat: TxCategory, total: Double)] = []
        var tail: [(cat: TxCategory, total: Double)] = []
        var tailCats: Set<TxCategory> = []
        var isEmpty: Bool { top.isEmpty && tail.isEmpty }
    }

    func categorySplit(_ rows: [TxRecord]) -> CategorySplit {
        let totals = Dictionary(grouping: rows, by: \.category)
            .map { (cat: $0.key, total: expenseSum($0.value)) }
            .sorted { $0.total > $1.total }
        let tail = Array(totals.dropFirst(4))
        return CategorySplit(top: Array(totals.prefix(4)),
                             tail: tail,
                             tailCats: Set(tail.map(\.cat)))
    }

    /// The rule a filter puts on a row. Returned as a predicate so the caller can
    /// apply the SAME test to its chart, its totals and its list.
    func matches(_ filter: CycleFilter,
                         tailCats: Set<TxCategory>) -> (TxRecord) -> Bool {
        switch filter {
        case .all:             return { _ in true }
        case .category(let c): return { $0.category == c }
        case .others:          return { tailCats.contains($0.category) }
        }
    }

    /// The chip bar shared by the cycle and weekly pages, so the two read alike.
    @ViewBuilder
    func categoryFilterBar(_ split: CategorySplit,
                                   selection: Binding<CycleFilter>,
                                   total: Double, count: Int) -> some View {
        if !split.isEmpty {
            let showTail: Bool = {
                switch selection.wrappedValue {
                case .others:          return true
                case .category(let c): return split.tailCats.contains(c)
                case .all:             return false
                }
            }()
            let label: String = {
                switch selection.wrappedValue {
                case .all:             return loc("stats.filter_all")
                case .category(let c): return c.displayLabel
                case .others:          return loc("stats.filter_others")
                }
            }()
            VStack(alignment: .leading, spacing: 10) {
                // Full-bleed like the Search filters: the scroll view spans the
                // screen and the 22pt inset lives on its content, so chips run to
                // the edge and scroll past it instead of being clipped 22pt in.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        categoryChip(loc("stats.filter_all"), .all, AppTheme.blue, selection)
                        ForEach(split.top, id: \.cat) { c in
                            categoryChip(c.cat.displayLabel, .category(c.cat), c.cat.color, selection)
                        }
                        if !split.tail.isEmpty {
                            categoryChip(loc("stats.filter_others"), .others, AppTheme.purple, selection)
                            // Once you're looking at the tail, its own chips appear —
                            // otherwise a small category could never be isolated.
                            if showTail {
                                ForEach(split.tail, id: \.cat) { c in
                                    categoryChip(c.cat.displayLabel, .category(c.cat), c.cat.color, selection)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 2)
                }
                .padding(.horizontal, -22)
                // What the filter currently adds up to, so the page is never a set
                // of figures with no total attached.
                HStack {
                    Text(label)
                        .font(.system(.caption, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Spacer()
                    Text("\(money(total)) · \(String(format: loc("stats.tx_count"), count))")
                        .font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
            }
        }
    }

    func categoryChip(_ label: String, _ value: CycleFilter, _ tint: Color,
                              _ selection: Binding<CycleFilter>) -> some View {
        let isOn = selection.wrappedValue == value
        return Button {
            HapticManager.shared.tap()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                // Tapping the active chip clears back to All.
                selection.wrappedValue = isOn ? .all : value
            }
        } label: {
            Text(label)
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(isOn ? AppTheme.onVividFill : AppTheme.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, 13).padding(.vertical, 8)
                .background(isOn ? tint : AppTheme.cardDark, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    func trendFigure(_ label: String, _ value: Double, _ tint: Color) -> some View {
        VStack(spacing: 3) {
            Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(AppTheme.textSecondary)
            Text(money(abs(value))).font(.system(.footnote, weight: .bold)).foregroundStyle(tint)
                .lineLimit(1).minimumScaleFactor(0.5)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Shared pieces for the two detail pages

    func statHero(title: String, subtitle: String, value: Double, tint: Color,
                          change: Double?, changeCaption: String, previous: Double) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(subtitle).font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
            }
            Text(money(value))
                .font(.system(size: 36, weight: .bold))
                .foregroundStyle(AppTheme.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.5)
                .contentTransition(.numericText())
            if let c = change {
                HStack(spacing: 6) {
                    HStack(spacing: 3) {
                        Image(systemName: c >= 0 ? "arrow.up.right" : "arrow.down.right")
                            .font(.system(.caption2, weight: .bold))
                        Text(String(format: "%.0f%%", abs(c))).font(.system(.caption2, weight: .bold))
                    }
                    .foregroundStyle(c >= 0 ? AppTheme.red : AppTheme.accent)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background((c >= 0 ? AppTheme.red : AppTheme.accent).opacity(0.15), in: Capsule())
                    Text("\(changeCaption) · \(money(previous))")
                        .font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: AppRadius.xl).fill(AppTheme.cardDark)
                .overlay {
                    LinearGradient(colors: [tint.opacity(0.20), tint.opacity(0.05), .clear],
                                   startPoint: .topTrailing, endPoint: .bottomLeading)
                }
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.xl))
        }
    }

    func chartCard(values: [Double], labels: [String], tint: Color,
                           highlightLast: Bool) -> some View {
        MiniBars(values: values, labels: labels, tint: tint,
                 highlightLast: highlightLast, height: 130, maxBarWidth: 34)
            .frame(maxWidth: .infinity)
            .padding(16)
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.xl))
    }

    func factTile(_ label: String, _ value: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(.subheadline, weight: .bold)).foregroundStyle(tint)
                .lineLimit(1).minimumScaleFactor(0.5)
            // A tick of the figure's own colour beside its name: three tiles in
            // a row under a chart are a key, and a key needs its colours.
            HStack(spacing: 5) {
                Capsule().fill(tint).frame(width: 3, height: 10)
                Text(label).font(.system(size: 10, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12).padding(.horizontal, 12)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
    }

    /// "25 Sep – 24 Oct" for the bubble: a period's name is a month, but the
    /// span it covers is not, and on a pay cycle those are different things.
    func cycleRangeLabel(_ p: CycleTrendPoint) -> String {
        let f = DateFormatterCache.template("dMMM")
        return "\(f.string(from: p.start)) – \(f.string(from: p.end))"
    }

    /// Every figure the summary is built from, for anyone who wants to check it:
    /// the balance reconciliation, the daily allowance and its audit, fixed
    /// payments priced in goal-time, the net trend and every pattern.
    var fullAnalysis: some View {
        ZStack {
            AppTheme.bg.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(periodSubtitle)
                            .font(.system(.footnote, weight: .semibold))
                            .foregroundStyle(AppTheme.textPrimary)
                        if let main = selectedCard {
                            Text(String(format: loc("stats.main_card_line"), cardLabel(main)))
                                .font(.system(.caption))
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                    }
                    .padding(.bottom, 4)

                    NetBalanceSummary(net: filteredIncome - filteredExpenses, income: filteredIncome,
                                      expenses: filteredExpenses, currency: displayCurrency,
                                      cardBalanceNow: selectedCard?.computedBalance(),
                                      startBalance: periodStartBalance,
                                      transferNet: periodTransferNet,
                                      progress: periodProgress,
                                      previousExpenses: previousPeriodExpenses)

                    // The trend's working lives here now: the main page carries a
                    // compact "Trends" tile, and this is the one tap away.
                    SpendingTrendCard(trend: netWorthTrend, currency: displayCurrency,
                                      byPayCycle: payCycleDay != nil)

                    if filteredExpenses > 0 {
                        let insightsCard = SmartInsightsCard(
                            weeklyAverage: weeklyAverage,
                            dailyAllowance: dailyAllowance,
                            irregular: irregularSpend,
                            topCategories: topCategories,
                            totalExpenses: filteredExpenses,
                            currency: displayCurrency,
                            isPartialPeriod: isPartialWeeklyPeriod,
                            periodDays: periodDays
                        )
                        if premiumMgr.canAccess(.smartBudget) {
                            insightsCard
                        } else {
                            insightsCard
                                .blur(radius: 7)
                                .allowsHitTesting(false)
                                .overlay { lockedInsightsOverlay }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    HapticManager.shared.tap()
                                    NotificationCenter.default.post(name: .requestOpenPaywall, object: nil)
                                }
                        }
                    }

                    if premiumMgr.canAccess(.smartBudget), !commitmentReview.lines.isEmpty {
                        CommitmentPriorityCard(review: commitmentReview,
                                               currency: displayCurrency,
                                               dailyAllowance: dailyAllowance,
                                               typicalDaily: typicalDailySpend,
                                               irregularThisCycle: irregularSpend.total,
                                               daysInCycle: periodProgress?.total ?? periodDays)
                    }

                    // No trend chart here. The net-flow bars repeated the spending
                    // chart on the main page in other colours; that chart's
                    // breakdown already lists money in, money out and the net for
                    // every period.

                    if premiumMgr.canAccess(.smartBudget), !patternRows.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(loc("stats.patterns"))
                                .font(.system(.body, weight: .bold))
                                .foregroundStyle(AppTheme.textPrimary)
                                .padding(.bottom, 4)
                            ForEach(Array(patternRows.enumerated()), id: \.offset) { _, row in
                                noteRow(row.icon, row.tint, row.title, row.detail)
                            }
                        }
                        .padding(16)
                        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.xl))
                    }

                    Spacer(minLength: 40)
                }
                .padding(.horizontal, 22)
                .padding(.top, 8)
            }
        }
        .navigationTitle(loc("stats.detail_title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(AppTheme.bg, for: .navigationBar)
    }
}
