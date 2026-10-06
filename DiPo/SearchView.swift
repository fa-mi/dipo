import SwiftUI
import SwiftData

// Moved out of UtilityViews.swift, unchanged.

// MARK: - Search Date Period

enum SearchPeriod: String, CaseIterable {
    case all_period, today_period, yesterday_period, week_period, month_period, three_month_period, year_period, custom

    // rawValue is a stable identifier — never display it directly.
    // title is resolved at render time via loc() so it follows the in-app language.
    var title: String {
        switch self {
        case .all_period:          return loc("search.period.all")
        case .today_period:        return loc("search.period.today")
        case .yesterday_period:    return loc("search.period.yesterday")
        case .week_period:         return loc("search.period.week")
        case .month_period:        return loc("search.period.month")
        case .three_month_period:  return loc("search.period.3month")
        case .year_period:         return loc("search.period.year")
        case .custom:              return loc("search.period.custom")
        }
    }

    func range() -> (start: Date, end: Date)? {
        let cal = Calendar.current
        let now = Date()

        switch self {
        case .all_period: return nil
        case .today_period:
            return (cal.startOfDay(for: now), now)

        // Calendar date math returns Optionals the compiler can't prove
        // non-nil. In practice these never fail for simple offsets near `now`,
        // but force-unwrapping is a latent crash; fall back to `now` instead.
        case .yesterday_period:
            let start = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now)) ?? cal.startOfDay(for: now)
            return (start, cal.startOfDay(for: now))

        case .week_period:
            let start = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)) ?? now
            return (start, now)

        case .month_period:
            return (cal.date(byAdding: .month, value: -1, to: now) ?? now, now)

        case .three_month_period:
            return (cal.date(byAdding: .month, value: -3, to: now) ?? now, now)

        case .year_period:
            let start = cal.date(from: cal.dateComponents([.year], from: now)) ?? now
            return (start, now)

        case .custom:
            return nil
        }
    }
}
// MARK: - Search engine
//
// Search used to re-sort EVERY transaction and re-filter the lot several times
// per redraw — once for the count, once for the total, once for the category
// pills, once per group — and on every keystroke. At five years of a busy
// ledger that was seconds per letter typed. It now runs once per change of
// what was asked, sorts on dates read once, and hands the screen only the
// rows it shows; the rest wait behind "Show more".

struct SearchResults {
    var count = 0
    /// Money out and money in among the matches, by Statistics' rules:
    /// transfers left out, a refund taking back its expense, income counting
    /// real income only — in the preferred currency. The single signed sum
    /// this replaced added everything: a salary, a loan paid back, both legs
    /// of a move between accounts, and spending, so a period that spent
    /// Rp 7.971.500 showed "+Rp 7.128.500".
    var spent = 0.0
    var received = 0.0
    /// Received less spent.
    var total: Double { received - spent }
    /// Categories present in the period, for the filter pills.
    var categories: [TxCategory] = []
    /// The rows shown, in order, grouped by day unless sorted by amount.
    var groups: [(day: Date, txs: [TxRecord])] = []
    /// Matching rows beyond `limit`.
    var hidden = 0
}

enum SearchEngine {
    static func run(_ all: [TxRecord], query: String, range: (start: Date, end: Date)?,
                    category: TxCategory?, sort: SearchView.SearchSort, limit: Int,
                    convert: (TxRecord) -> Double, cal: Calendar = .current) -> SearchResults {
        var out = SearchResults()
        let inPeriod = range.map { r in all.filter { $0.date >= r.start && $0.date <= r.end } } ?? all
        let used = Set(inPeriod.map(\.category))
        out.categories = TxCategory.allCases.filter { used.contains($0) }

        var matches = inPeriod
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            matches = matches.filter {
                $0.name.lowercased().contains(q) || $0.type.lowercased().contains(q)
                    || $0.category.rawValue.lowercased().contains(q) || $0.displayNotes.lowercased().contains(q)
            }
        }
        if let category { matches = matches.filter { $0.category == category } }

        out.count = matches.count
        out.spent = max(StatisticsView.expenses(matches, convert: convert), 0)
        out.received = StatisticsView.income(matches, convert: convert)

        // Each key read once: comparing model properties inside the sort
        // reads them n·log n times, and that was most of the cost.
        let shown: [TxRecord]
        if sort.isByAmount {
            let keyed = matches.map { (key: abs(convert($0)), tx: $0) }
            shown = keyed.sorted { sort == .largest ? $0.key > $1.key : $0.key < $1.key }
                .prefix(limit).map(\.tx)
        } else {
            let keyed = matches.map { (key: $0.date, tx: $0) }
            shown = keyed.sorted { sort == .newest ? $0.key > $1.key : $0.key < $1.key }
                .prefix(limit).map(\.tx)
        }
        out.hidden = max(matches.count - shown.count, 0)

        if sort.isByAmount {
            out.groups = shown.isEmpty ? [] : [(day: .distantPast, txs: shown)]
        } else {
            // `shown` is already in order, so days come out in order too.
            for tx in shown {
                let day = cal.startOfDay(for: tx.date)
                if out.groups.last?.day == day { out.groups[out.groups.count - 1].txs.append(tx) }
                else { out.groups.append((day: day, txs: [tx])) }
            }
        }
        return out
    }
}

// MARK: - Search View

struct SearchView: View {
    let vm: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selectedFilter: TxCategory? = nil
    @State private var selectedPeriod: SearchPeriod = .all_period
    /// How results are ordered.
    ///
    /// Sorting by amount deliberately DROPS the per-day grouping. A list headed
    /// "Yesterday / Wednesday / Monday" that claims to be largest-first is still
    /// ordered by date — the biggest transaction of Monday would sit below the
    /// smallest of yesterday. You cannot have both orders at once, so asking for
    /// one abandons the other rather than pretending.
    enum SearchSort: CaseIterable {
        case newest, oldest, largest, smallest

        var titleKey: String {
            switch self {
            case .newest:   return "search.sort.newest"
            case .oldest:   return "search.sort.oldest"
            case .largest:  return "search.sort.largest"
            case .smallest: return "search.sort.smallest"
            }
        }
        var icon: String {
            switch self {
            case .newest:   return "arrow.down"
            case .oldest:   return "arrow.up"
            case .largest:  return "arrow.down.to.line"
            case .smallest: return "arrow.up.to.line"
            }
        }
        var isByAmount: Bool { self == .largest || self == .smallest }
    }
    @State private var sort: SearchSort = .newest
    @State private var results = SearchResults()
    @State private var lastQuery = ""
    /// Rows shown; "Show more" adds a page.
    @State private var limit = SearchView.pageSize
    static let pageSize = 200
    @State private var appeared = false
    @FocusState private var focused: Bool
    @State private var selectedTx: TxRecord? = nil
    @State private var showCustomDateSheet = false
    @State private var customStart: Date = Calendar.current.safeDate(byAdding: .month, value: -1, to: Date())
    @State private var customEnd: Date = Date()

    /// Every transaction, unsorted: the engine orders only what it shows.
    private var allTransactions: [TxRecord] { vm.cards.flatMap(\.transactions) }

    private var range: (start: Date, end: Date)? {
        if selectedPeriod == .custom {
            let end = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: customEnd) ?? customEnd
            return (customStart, end)
        }
        return selectedPeriod.range()
    }

    /// Everything a search depends on; a change re-runs it, nothing else does.
    private struct Request: Hashable {
        var query: String, period: SearchPeriod, category: TxCategory?, sort: SearchSort
        var customStart: Date, customEnd: Date, limit: Int, txCount: Int
    }
    private var request: Request {
        Request(query: query, period: selectedPeriod, category: selectedFilter, sort: sort,
                customStart: customStart, customEnd: customEnd, limit: limit,
                txCount: vm.cards.reduce(0) { $0 + $1.transactions.count })
    }

    private func dayLabel(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return loc("common.today") }
        if cal.isDateInYesterday(day) { return loc("common.yesterday") }
        let weekAgo = cal.safeDate(byAdding: .day, value: -7, to: Date())
        return DateFormatterCache.template(day >= weekAgo ? "EEEE" : "dMMMMyyyy").string(from: day)
    }

    private var pref: String { CurrencyManager.shared.preferredCurrency }

    /// A day's money out and in, by the same rules as the summary.
    private func dayFigures(_ txs: [TxRecord]) -> (spent: Double, received: Double) {
        (max(StatisticsView.expenses(txs, convert: convertedForSort), 0),
         StatisticsView.income(txs, convert: convertedForSort))
    }

    @ViewBuilder
    private func moneyPair(spent: Double, received: Double, font: Font) -> some View {
        HStack(spacing: 8) {
            if spent >= 1 {
                Text("−" + CurrencyManager.shared.formatted(spent, currency: pref))
                    .foregroundStyle(AppTheme.red)
            }
            if received >= 1 {
                Text("+" + CurrencyManager.shared.formatted(received, currency: pref))
                    .foregroundStyle(AppTheme.accent)
            }
        }
        .font(font)
        .lineLimit(1).minimumScaleFactor(0.7)
    }

    private func summaryFigure(_ label: String, _ value: Double, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
            Text(CurrencyManager.shared.formatted(value, currency: pref))
                .font(.system(.subheadline, weight: .bold)).foregroundStyle(tint)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
    }

    /// Ranking across mixed currencies has to compare like with like, or a
    /// $10 purchase sorts below a Rp 20.000 one on the raw number alone.
    private func convertedForSort(_ tx: TxRecord) -> Double {
        let pref = CurrencyManager.shared.preferredCurrency
        return CurrencyManager.shared.convert(
            tx.amount, from: tx.currency.isEmpty ? pref : tx.currency, to: pref)
    }

    var body: some View {
        ZStack(alignment: .top) {
            AppTheme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                // Search bar
                    HStack(spacing: 12) {
                        HStack(spacing: 10) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(.callout))
                                .foregroundStyle(AppTheme.textSecondary)
                            TextField(loc("search.placeholder"), text: $query)
                                .font(.system(.callout))
                                .foregroundStyle(AppTheme.textPrimary)
                                .focused($focused)
                                .autocorrectionDisabled()
                            if !query.isEmpty {
                                Button { query = "" } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(.callout))
                                        .foregroundStyle(AppTheme.textSecondary)
                                }
.accessibilityLabel(loc("a11y.clear_search"))
                            }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 12)
                        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
                        .overlay(RoundedRectangle(cornerRadius: AppRadius.md)
                            .stroke(focused ? AppTheme.accent.opacity(0.5) : Color.clear, lineWidth: 1.5))

                        Button(loc("common.cancel")) { HapticManager.shared.tap(); dismiss() }
                            .foregroundStyle(AppTheme.textSecondary).font(.system(.subheadline))
                    }
                    .padding(.horizontal, 22).padding(.top, 16).padding(.bottom, 10)

                    // Date period pills
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(SearchPeriod.allCases, id: \.self) { period in
                                Button {
                                    HapticManager.shared.tap()
                                    withAnimation(.spring(response: 0.3)) { selectedPeriod = period }
                                    if period == .custom { showCustomDateSheet = true }
                                } label: {
                                    HStack(spacing: 5) {
                                        if period != .all_period {
                                            Image(systemName: "calendar")
                                                .font(.system(.caption2, weight: .medium)).imageScale(.small)
                                        }
                                        if period == .custom && selectedPeriod == .custom {
                                            // Show the selected date range, locale-aware
                                            let locale = LanguageManager.shared.currentLocale
                                            let df: DateFormatter = {
                                                let f = DateFormatter()
                                                f.locale = locale
                                                f.dateFormat = DateFormatter.dateFormat(fromTemplate: "d MMM", options: 0, locale: locale)
                                                return f
                                            }()
                                            Text("\(df.string(from: customStart)) – \(df.string(from: customEnd))")
                                                .font(.system(.caption, weight: .semibold))
                                        } else {
                                            Text(period.title)
                                                .font(.system(size: 12, weight: selectedPeriod == period ? .semibold : .regular))
                                        }
                                    }
                                    .foregroundStyle(selectedPeriod == period ? AppTheme.onVividFill : AppTheme.textSecondary)
                                    .padding(.horizontal, 12).padding(.vertical, 7)
                                    .background(selectedPeriod == period ? AppTheme.accentFill : AppTheme.cardDark, in: Capsule())
                                }
                                .buttonStyle(ScaleButtonStyle())
                            }
                        }
                        .padding(.horizontal, 22)
                    }
                    .padding(.bottom, 8)

                    // Category filter pills
                    if !results.categories.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                FilterPill(label: loc("search.all_categories"), isSelected: selectedFilter == nil) {
                                    HapticManager.shared.tap()
                                    withAnimation(.spring(response: 0.3)) { selectedFilter = nil }
                                }
                                ForEach(results.categories, id: \.self) { cat in
                                    FilterPill(label: cat.shortLabel, isSelected: selectedFilter == cat, color: cat.color) {
                                        HapticManager.shared.tap()
                                        withAnimation(.spring(response: 0.3)) {
                                            selectedFilter = selectedFilter == cat ? nil : cat
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 22)
                        }
                        .padding(.bottom, 10)
                    }

                    Divider().background(AppTheme.cardMid)

                    if results.count == 0 {
                        VStack(spacing: 14) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 40)).foregroundStyle(AppTheme.textSecondary)
                            Text(query.isEmpty ? loc("search.nil_period") : String(format: loc("search.no_results"), query))
                                .font(.system(.subheadline)).foregroundStyle(AppTheme.textSecondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.top, 80)
                    } else {
                        ScrollView(showsIndicators: false) {
                            VStack(spacing: 0) {
                                // Summary bar
                                HStack {
                                    let fmt = results.count == 1
                                        ? loc("search.result_count")
                                        : loc("search.results_count")
                                    Text(String(format: fmt, results.count))
                                        .font(.system(.footnote)).foregroundStyle(AppTheme.textSecondary)
                                    // Order: by time, or by amount.
                                    Menu {
                                        ForEach(SearchSort.allCases, id: \.self) { option in
                                            Button {
                                                HapticManager.shared.tap()
                                                withAnimation(AppMotion.move) { sort = option }
                                            } label: {
                                                Label(loc(option.titleKey),
                                                      systemImage: sort == option ? "checkmark" : option.icon)
                                            }
                                        }
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: "arrow.up.arrow.down")
                                                .font(.system(.caption2, weight: .semibold)).imageScale(.small)
                                            Text(loc(sort.titleKey))
                                                .font(.system(.caption, weight: .medium))
                                        }
                                        .foregroundStyle(AppTheme.accent)
                                        .padding(.horizontal, 10).padding(.vertical, 5)
                                        .background(AppTheme.accent.opacity(0.1), in: Capsule())
                                    }
                                    .padding(.leading, 10)
                                    Spacer()
                                }
                                .padding(.horizontal, 22).padding(.top, 12)

                                // Money out and in, each on its own — never one
                                // signed sum of spending, salary and transfers.
                                if results.spent >= 1 || results.received >= 1 {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack(spacing: 16) {
                                            if results.spent >= 1 {
                                                summaryFigure(loc("search.spent"), results.spent, AppTheme.red)
                                            }
                                            if results.received >= 1 {
                                                summaryFigure(loc("search.received"), results.received, AppTheme.accent)
                                            }
                                            Spacer(minLength: 0)
                                        }
                                        Text(loc("search.sum_note"))
                                            .font(.system(.caption2))
                                            .foregroundStyle(AppTheme.textSecondary)
                                    }
                                    .padding(.horizontal, 22).padding(.top, 8)
                                }
                                Color.clear.frame(height: 12)

                                // Grouped results
                                LazyVStack(spacing: 20) {
                                    ForEach(results.groups, id: \.day) { group in
                                        let label = group.day == .distantPast ? "" : dayLabel(group.day)
                                        VStack(alignment: .leading, spacing: 8) {
                                            // Group header
                                            let figures = dayFigures(group.txs)
                                            // Empty label = the flat, amount-ordered list. A
                                            // running total across unrelated days would be a
                                            // number about nothing.
                                            if !label.isEmpty {
                                            HStack {
                                                Text(label)
                                                    .font(.system(.footnote, weight: .semibold))
                                                    .foregroundStyle(AppTheme.textSecondary)
                                                Spacer()
                                                moneyPair(spent: figures.spent, received: figures.received,
                                                          font: .system(.caption, weight: .medium))
                                            }
                                            .padding(.horizontal, 22)
                                            }

                                            VStack(spacing: 0) {
                                                ForEach(group.txs) { tx in
                                                    Button { selectedTx = tx } label: {
                                                        SearchTxRow(tx: tx, query: query)
                                                            .padding(.horizontal, 22)
                                                    }
                                                    .buttonStyle(ScaleButtonStyle())
                                                    if tx.id != group.txs.last?.id {
                                                        Divider().background(AppTheme.cardMid).padding(.horizontal, 22)
                                                    }
                                                }
                                            }
                                            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
                                            .padding(.horizontal, 22)
                                        }
                                    }
                                }
                                .padding(.bottom, results.hidden > 0 ? 12 : 40)

                                if results.hidden > 0 {
                                    Button {
                                        HapticManager.shared.tap()
                                        limit += SearchView.pageSize
                                    } label: {
                                        Text(String(format: loc("search.show_more"),
                                                    min(results.hidden, SearchView.pageSize), results.hidden))
                                            .font(.system(.footnote, weight: .semibold))
                                            .foregroundStyle(AppTheme.accent)
                                            .padding(.horizontal, 16).padding(.vertical, 10)
                                            .background(AppTheme.accent.opacity(0.1), in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.bottom, 40)
                                }
                            }
                            .containerRelativeFrame(.horizontal)
                        }
                    }
                }
            }
            .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { focused = true }
        }
        // One search per change of what was asked. Typing waits a beat so a
        // word runs once, not once per letter; a new question starts from the
        // first page again.
        .task(id: request) {
            let req = request
            if !req.query.isEmpty, req.query != lastQuery {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
            }
            lastQuery = req.query
            results = SearchEngine.run(allTransactions, query: req.query, range: range,
                                       category: req.category, sort: req.sort, limit: req.limit,
                                       convert: convertedForSort)
        }
        .onChange(of: query) { _, _ in limit = SearchView.pageSize }
        .onChange(of: selectedPeriod) { _, _ in limit = SearchView.pageSize }
        .onChange(of: selectedFilter) { _, _ in limit = SearchView.pageSize }
        .sheet(item: $selectedTx) { tx in
            TransactionDetailSheet(tx: tx)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
                .preferredColorScheme(appColorScheme())
        }
        .sheet(isPresented: $showCustomDateSheet) {
            CustomDateRangeSheet(startDate: $customStart, endDate: $customEnd)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
                .preferredColorScheme(appColorScheme())
        }
    }
}

struct FilterPill: View {
    let label: String
    let isSelected: Bool
    var color: Color = AppTheme.accent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? AppTheme.bg : AppTheme.textSecondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(isSelected ? color : AppTheme.cardDark, in: Capsule())
        }
        .buttonStyle(ScaleButtonStyle())
    }
}

struct SearchTxRow: View {
    let tx: TxRecord
    let query: String

    private var formattedDate: String {
        let cal = Calendar.current
        let locale = LanguageManager.shared.currentLocale
        let df = DateFormatter()
        df.locale = locale
        df.dateFormat = DateFormatter.dateFormat(fromTemplate: "j:mm", options: 0, locale: locale)
        let timeStr = df.string(from: tx.date)
        if cal.isDateInToday(tx.date)     { return "\(loc("common.today")), \(timeStr)" }
        if cal.isDateInYesterday(tx.date) { return "\(loc("common.yesterday")), \(timeStr)" }
        let df2 = DateFormatter()
        df2.locale = locale
        df2.dateFormat = DateFormatter.dateFormat(fromTemplate: "d MMM j:mm", options: 0, locale: locale)
        return df2.string(from: tx.date)
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: AppRadius.sm)
                    .fill(tx.displayIconBg)
                    .frame(width: 42, height: 42)
                Text(tx.icon)
                    .font(.system(size: tx.icon.count == 1 ? 15 : 18))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(tx.name)
                    .font(.system(.subheadline, weight: .medium))
                    .foregroundStyle(AppTheme.textPrimary)
                HStack(spacing: 6) {
                    Text(formattedDate)
                        .font(.system(.caption2))
                        .foregroundStyle(AppTheme.textSecondary)
                        // The date yields first. A truncated date is still
                        // readable; a wrapped category chip ("Commitm/ent")
                        // reads as a rendering fault.
                        .lineLimit(1)
                        .layoutPriority(0)
                    Text(tx.category.shortLabel)
                        .font(.system(.caption2, weight: .medium))
                        .foregroundStyle(tx.category.color)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(tx.category.color.opacity(0.12), in: Capsule())
                        .layoutPriority(1)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(CurrencyManager.shared.formatted(abs(tx.amount), currency: tx.currency))
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(tx.amount >= 0 ? AppTheme.green : AppTheme.textPrimary)
                if tx.amount >= 0 {
                    Text(loc("home.income")).font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
                } else {
                    Text(tx.displayType).font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
                }
            }
        }
        .padding(.vertical, 6)
    }
}
