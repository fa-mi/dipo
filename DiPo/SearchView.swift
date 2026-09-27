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
    @State private var appeared = false
    @FocusState private var focused: Bool
    @State private var selectedTx: TxRecord? = nil
    @State private var showCustomDateSheet = false
    @State private var customStart: Date = Calendar.current.safeDate(byAdding: .month, value: -1, to: Date())
    @State private var customEnd: Date = Date()

    var allTransactions: [TxRecord] { vm.recentTransactions }

    var periodFiltered: [TxRecord] {
        if selectedPeriod == .custom {
            let end = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: customEnd) ?? customEnd
            return allTransactions.filter { $0.date >= customStart && $0.date <= end }
        }
        guard let range = selectedPeriod.range() else { return allTransactions }
        return allTransactions.filter { $0.date >= range.start && $0.date <= range.end }
    }

    var filtered: [TxRecord] {
        var result = periodFiltered
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            let q = query.lowercased()
            result = result.filter {
                $0.name.lowercased().contains(q) ||
                $0.type.lowercased().contains(q) ||
                $0.category.rawValue.lowercased().contains(q) ||
                $0.notes.lowercased().contains(q)
            }
        }
        if let cat = selectedFilter {
            result = result.filter { $0.category == cat }
        }
        return result
    }

    // Group filtered results by date section
    var grouped: [(label: String, date: Date, txs: [TxRecord])] {
        let cal = Calendar.current
        var dict: [Date: [TxRecord]] = [:]
        for tx in filtered {
            let day = cal.startOfDay(for: tx.date)
            dict[day, default: []].append(tx)
        }
        // By amount: one flat section, no day headers — see `SearchSort`.
        if sort.isByAmount {
            let ordered = filtered.sorted {
                let a = abs(convertedForSort($0)), b = abs(convertedForSort($1))
                return sort == .largest ? a > b : a < b
            }
            return ordered.isEmpty ? [] : [(label: "", date: Date.distantPast, txs: ordered)]
        }
        return dict.keys.sorted(by: sort == .newest ? (>) : (<)).map { day in
            let label: String
            if cal.isDateInToday(day)          { label = loc("common.today") }
            else if cal.isDateInYesterday(day) { label = loc("common.yesterday") }
            else {
                let weekAgo = cal.safeDate(byAdding: .day, value: -7, to: Date())
                let df: DateFormatter
                if day >= weekAgo {
                    df = DateFormatterCache.template("EEEE")
                } else {
                    df = DateFormatterCache.template("dMMMMyyyy")
                }
                label = df.string(from: day)
            }
            let dayTxs = (dict[day] ?? []).sorted { sort == .newest ? $0.date > $1.date : $0.date < $1.date }
            return (label: label, date: day, txs: dayTxs)
        }
    }

    /// Ranking across mixed currencies has to compare like with like, or a
    /// $10 purchase sorts below a Rp 20.000 one on the raw number alone.
    private func convertedForSort(_ tx: TxRecord) -> Double {
        let pref = CurrencyManager.shared.preferredCurrency
        return CurrencyManager.shared.convert(
            tx.amount, from: tx.currency.isEmpty ? pref : tx.currency, to: pref)
    }

    var availableCategories: [TxCategory] {
        let used = Set(periodFiltered.map { $0.category })
        return TxCategory.allCases.filter { used.contains($0) }
    }

    var totalAmount: Double { filtered.reduce(0) { $0 + $1.amount } }

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
                    if !availableCategories.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                FilterPill(label: loc("search.all_categories"), isSelected: selectedFilter == nil) {
                                    HapticManager.shared.tap()
                                    withAnimation(.spring(response: 0.3)) { selectedFilter = nil }
                                }
                                ForEach(availableCategories, id: \.self) { cat in
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

                    if filtered.isEmpty {
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
                                    let fmt = filtered.count == 1
                                        ? loc("search.result_count")
                                        : loc("search.results_count")
                                    Text(String(format: fmt, filtered.count))
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
                                    Text(totalAmount >= 0
                                         ? "+\(CurrencyManager.shared.formatted(totalAmount, currency: filtered.first?.currency ?? CurrencyManager.shared.preferredCurrency))"
                                         : CurrencyManager.shared.formatted(totalAmount, currency: filtered.first?.currency ?? CurrencyManager.shared.preferredCurrency))
                                        .font(.system(.footnote, weight: .semibold))
                                        .foregroundStyle(totalAmount >= 0 ? AppTheme.accent : AppTheme.red)
                                }
                                .padding(.horizontal, 22).padding(.vertical, 12)

                                // Grouped results
                                VStack(spacing: 20) {
                                    ForEach(grouped, id: \.date) { group in
                                        VStack(alignment: .leading, spacing: 8) {
                                            // Group header
                                            let groupTotal = group.txs.reduce(0) { $0 + $1.amount }
                                            // Empty label = the flat, amount-ordered list. A
                                            // running total across unrelated days would be a
                                            // number about nothing.
                                            if !group.label.isEmpty {
                                            HStack {
                                                Text(group.label)
                                                    .font(.system(.footnote, weight: .semibold))
                                                    .foregroundStyle(AppTheme.textSecondary)
                                                Spacer()
                                                Text(groupTotal >= 0
                                                     ? "+\(CurrencyManager.shared.formatted(groupTotal, currency: group.txs.first?.currency ?? CurrencyManager.shared.preferredCurrency))"
                                                     : CurrencyManager.shared.formatted(groupTotal, currency: group.txs.first?.currency ?? CurrencyManager.shared.preferredCurrency))
                                                    .font(.system(.caption, weight: .medium))
                                                    .foregroundStyle(groupTotal >= 0 ? AppTheme.accent.opacity(0.8) : AppTheme.red.opacity(0.8))
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
                                .padding(.bottom, 40)
                            }
                            .containerRelativeFrame(.horizontal)
                        }
                    }
                }
            }
            .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { focused = true }
        }
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
