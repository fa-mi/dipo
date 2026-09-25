import SwiftUI
import SwiftData


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

// MARK: - Transaction Detail + Edit Sheet

struct TransactionDetailSheet: View {
    @Bindable var tx: TxRecord
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var isEditing = false
    @State private var editName = ""
    @State private var editAmount = ""
    @State private var editCurrency = CurrencyManager.shared.preferredCurrency
    @State private var editType: EditType = .expense
    @State private var editCategory: TxCategory = .other
    @State private var editDate = Date()
    @State private var editNotes = ""
    /// Non-nil while the delete confirmation is up. Holds the tx so the sheet
    /// is the same `DeleteTransactionSheet` the swipe gesture opens.
    @State private var pendingDelete: TxRecord? = nil
    
    /// History the rhythm is measured over: every transaction on this card, not
    /// just this one. Cadence is a property of a habit, not of a purchase.
    @Query private var allCards: [BankCard]
    private var detailHistory: [TxRecord] {
        allCards.first { $0.transactions.contains(where: { $0.id == tx.id }) }?.transactions ?? []
    }

    /// Built once when the sheet opens, not on every body evaluation — the
    /// model takes medians across the whole card history, which is a full pass
    /// and has no business running as a side effect of a redraw.
    @State private var cachedRhythm = SpendingRhythm(history: []) { _ in 0 }

    private func explanationKey(for v: SpendingRhythm.Verdict) -> String {
        switch v {
        case .episodicCategory: return "tx.rhythm_why_episodic"
        case .outlier:          return "tx.rhythm_why_outlier"
        case .dayToDay:         return "tx.rhythm_why_daily"
        case .userMarked:       return "tx.rhythm_why_daily"
        }
    }

    private func overrideChip(_ title: String, value: Bool?) -> some View {
        let on = tx.oneOffOverride == value
        return Button {
            HapticManager.shared.tap()
            tx.oneOffOverride = value
            try? context.save()
        } label: {
            Text(title)
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(on ? AppTheme.onVividFill : AppTheme.textSecondary)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(on ? AppTheme.accentFill : AppTheme.cardMid, in: Capsule())
        }
        .buttonStyle(ScaleButtonStyle())
    }

    /// Locale-aware short time formatter (e.g. "12:30 PM" / "12.30")
    static func shortTimeString(from date: Date) -> String {
        let df = DateFormatter()
        df.locale = LanguageManager.shared.currentLocale
        df.timeStyle = .short
        df.dateStyle = .none
        return df.string(from: date)
    }

    enum EditType: String, CaseIterable {
        case expense = "Expense"
        case income  = "Income"
        /// Used only as a solid fill (the type capsule, the Record button), so
        /// it takes the fill tokens. Reading `AppTheme.red` here is what
        /// dragged the light-mode button from salmon to a hard red when `red`
        /// was darkened for TEXT legibility — a change the fill never needed.
        var color: Color { self == .expense ? AppTheme.redFill : AppTheme.accentFill }
        /// Same glyphs as the create form's type picker.
        var icon: String { self == .expense ? "arrow.up.circle.fill" : "arrow.down.circle.fill" }

        /// Localized label for the segmented picker. The rawValue stays English
        /// since it's used purely internally (Hashable for ForEach); it never
        /// reaches the UI.
        var localizedLabel: String {
            switch self {
            case .expense: return loc("tx.type.purchase")
            case .income:  return loc("tx.type.income")
            }
        }
    }

    private var formattedAmount: String {
        CurrencyManager.shared.formatted(abs(tx.amount), currency: tx.currency)
    }

    private var convertedLabel: String {
        let pref = CurrencyManager.shared.preferredCurrency
        let other = tx.currency == pref ? "USD" : pref
        let converted = CurrencyManager.shared.convert(abs(tx.amount), from: tx.currency, to: other)
        return "= \(CurrencyManager.shared.formatted(converted, currency: other))"
    }

    /// Categories valid for the current edit type. Mirrors AddTransactionSheet
    /// exactly so editing feels identical to creating: pick Income and you only
    /// see income categories, pick Expense and only expense ones — never the
    /// two mixed together.
    private var availableCategories: [TxCategory] {
        switch editType {
        // `.debtPayment` belongs here. Without it, someone paying off a credit
        // card by hand had no honest option and reached for "Other" — which is
        // how a Rp 1.000.000 debt repayment ended up inside this user's daily
        // spending pattern, month after month. The two menu flows (Debt Tracker
        // and the CC bill screen) always categorised it correctly; the manual
        // path was the one with no right answer.
        case .expense: return [.shopping, .food, .travel, .bills, .transport,
                               .health, .commitment, .investment, .debtPayment, .other]
        case .income:  return [.salary, .freelance, .business, .investment, .bonus, .gift, .incomeOther]
        }
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {
                        if isEditing {
                            editForm
                        } else {
                            detailView
                        }
                    }
                    .padding(.top, 8)
                    .containerRelativeFrame(.horizontal)
                }
            }
            .navigationTitle(isEditing ? loc("tx.edit.title") : loc("tx.detail.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isEditing ? loc("common.cancel") : loc("common.close")) {
                        if isEditing {
                            withAnimation { isEditing = false }
                        } else {
                            dismiss()
                        }
                    }
                    .foregroundStyle(AppTheme.textSecondary)
                }
                ToolbarItem(placement: .primaryAction) {
                    // While editing, Save lives at the bottom of the form, as it
                    // does when creating — not in two places at once.
                    if !isEditing {
                        Button {
                            loadEditState()
                            withAnimation { isEditing = true }
                        } label: {
                            Image(systemName: "pencil")
                                .foregroundStyle(AppTheme.accent)
                        }
.accessibilityLabel(loc("common.edit"))
                    }
                }
            }
        }
        .onAppear {
            cachedRhythm = SpendingRhythm(history: detailHistory) { t in
                CurrencyManager.shared.convert(
                    t.amount,
                    from: t.currency.isEmpty ? CurrencyManager.shared.preferredCurrency : t.currency,
                    to: CurrencyManager.shared.preferredCurrency)
            }
        }
        .sheet(item: $pendingDelete) { pending in
            DeleteTransactionSheet(
                tx: pending,
                card: allCards.first { $0.transactions.contains(where: { $0.id == pending.id }) },
                onConfirm: {
                    pendingDelete = nil
                    dismiss()
                    // Delete once both sheets have gone: deleting first leaves the
                    // closing detail sheet re-rendering a detached model.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        deleteTransactionWithGoalRollback(pending, context: context)
                        try? context.save()
                        HapticManager.shared.success()
                    }
                },
                onCancel: { pendingDelete = nil })
            .preferredColorScheme(appColorScheme())
        }
        .trackScreen(.transactionDetail)
    }

    /// A short, stable handle for one transaction, taken from the id it already
    /// has. Printed on the ticket so a person can point at a row when they ask
    /// about it instead of describing "the coffee one, on Tuesday, I think".
    private var reference: String {
        "TRX-" + tx.id.uuidString.prefix(8)
    }

    /// One line of particulars. No rules between rows: on a ticket the columns
    /// do that work, and a divider every 30pt turns paper back into a table.
    private func ticketRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(.footnote))
                .foregroundStyle(AppTheme.textSecondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(.footnote, weight: .medium))
                .foregroundStyle(AppTheme.textPrimary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 7)
    }

    // MARK: Detail view

    var detailView: some View {
        VStack(spacing: 20) {
            // The transaction as the object it already is: one purchase, one
            // moment, one piece of paper. Everything the stack of cards showed
            // is still here — the same facts, printed rather than filed.
            TicketCard {
                VStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: AppRadius.lg)
                            .fill(tx.displayIconBg)
                            .frame(width: 64, height: 64)
                        Text(tx.icon)
                            .font(.system(size: tx.icon.count == 1 ? 24 : 30))
                            .foregroundStyle(.white)
                    }

                    // Subtype badge — appears above the amount when the tx has
                    // been marked as Refund or Transfer. Visual cue that this tx
                    // is treated specially in budget calculations (refund
                    // subtracts from bucket; transfer is ignored entirely).
                    if tx.txSubtype != .normal {
                        HStack(spacing: 5) {
                            Image(systemName: tx.txSubtype.icon)
                                .font(.system(.caption2, weight: .semibold)).imageScale(.small)
                            Text(tx.txSubtype.displayLabel)
                                .font(.system(.caption2, weight: .bold))
                                .lineLimit(1)
                        }
                        .foregroundStyle(AppTheme.orange)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(AppTheme.orange.opacity(0.15), in: Capsule())
                        .fixedSize()
                    }

                    Text(tx.amount >= 0 ? "+\(formattedAmount)" : "-\(formattedAmount)")
                        .font(.system(.largeTitle, weight: .bold))
                        // The same money-in / money-out pair as Home's flow card.
                        .foregroundStyle(tx.amount >= 0 ? AppTheme.flowIn : AppTheme.flowOut)
                        .lineLimit(1).minimumScaleFactor(0.6)

                    Text(tx.name)
                        .font(.system(.subheadline, weight: .medium))
                        .foregroundStyle(AppTheme.textPrimary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    if tx.isFXConverted {
                        // Settled row: show what was declared and the rate applied
                        // on the charge day. This deliberately REPLACES the live
                        // conversion below — re-converting an amount that was
                        // already converted once would print a figure that
                        // contradicts the one actually posted to the balance.
                        VStack(spacing: 4) {
                            Text(String(format: loc("tx.fx_original"),
                                        CurrencyManager.shared.formatted(abs(tx.fxOriginalAmount),
                                                                         currency: tx.fxOriginalCurrency)))
                                .font(.system(.subheadline))
                                .foregroundStyle(AppTheme.textSecondary)
                            Text(String(format: loc("tx.fx_rate_used"),
                                        CurrencyManager.symbol(for: tx.fxOriginalCurrency),
                                        CurrencyManager.shared.formatted(tx.fxRate, currency: tx.currency)))
                                .font(.system(.caption2))
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                    } else {
                        Text(convertedLabel)
                            .font(.system(.subheadline))
                            .foregroundStyle(AppTheme.textSecondary)

                        if CurrencyManager.shared.isLoading {
                            HStack(spacing: 6) {
                                ProgressView().scaleEffect(0.7).tint(AppTheme.textSecondary)
                                Text(loc("common.updating_rate")).font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
                            }
                        } else if let updated = CurrencyManager.shared.lastUpdated {
                            Text(String(format: loc("common.rate_as_of"),
                                        CurrencyManager.shared.rateLabel,
                                        Self.shortTimeString(from: updated)))
                                .font(.system(.caption2))
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                    }
                }
            } particulars: {
                VStack(spacing: 0) {
                    ticketRow(loc("common.date"), tx.displayDate)
                    ticketRow(loc("common.category"), tx.category.displayLabel)
                    ticketRow(loc("common.type"), tx.displayType)
                    ticketRow(loc("common.currency"), tx.currency)
                    if !tx.notes.isEmpty {
                        ticketRow(loc("common.notes"), tx.displayNotes)
                    }
                    ticketRow(loc("tx.reference"), reference)

                    TicketBarcode(id: tx.id)
                        .padding(.top, 14)
                    Text(reference)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(AppTheme.textSecondary)
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 8)

            // The engine's call on whether this is day-to-day spending, and a
            // way to disagree with it.
            //
            // Shown rather than hidden, because a number that quietly excludes
            // some of your spending is a number you cannot check. And the
            // correction is three-state on purpose: "automatic" has to remain
            // reachable, or the first tap is irreversible and people stop
            // tapping.
            if tx.amount < 0, tx.txSubtype != .transfer,
               !StatisticsView.fixedMonthlyCats.contains(tx.category) {
                let amount = abs(CurrencyManager.shared.convert(
                    tx.amount, from: tx.currency.isEmpty ? CurrencyManager.shared.preferredCurrency : tx.currency,
                    to: CurrencyManager.shared.preferredCurrency))
                let auto = cachedRhythm.autoVerdict(for: tx, amount: amount)

                VStack(alignment: .leading, spacing: 10) {
                    Text(loc("tx.rhythm_title"))
                        .font(.system(.caption2, weight: .bold))
                        .foregroundStyle(AppTheme.textSecondary)
                        .tracking(0.6)

                    Text(loc(explanationKey(for: auto)))
                        .font(.system(.caption))
                        .foregroundStyle(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 6) {
                        overrideChip(loc("tx.rhythm_auto"),   value: nil)
                        overrideChip(loc("tx.rhythm_daily"),  value: false)
                        overrideChip(loc("tx.rhythm_irreg"),  value: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
                .padding(.horizontal, 22)
            }

            // Refund/transfer tagging was removed — if a transaction was a
            // refund, the user simply deletes it (the money came back, so the
            // expense shouldn't exist). Transfers are still created/tagged by
            // the dedicated Transfer feature; they just don't expose a manual
            // tag/reset control here.

            // Delete button
            Button {
                HapticManager.shared.warning()
                pendingDelete = tx
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "trash").font(.system(.callout))
                    Text(loc("tx.delete")).font(.system(.subheadline, weight: .semibold))
                }
                .foregroundStyle(AppTheme.red)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(AppTheme.red.opacity(0.1), in: RoundedRectangle(cornerRadius: AppRadius.md))
                .overlay(RoundedRectangle(cornerRadius: AppRadius.md).stroke(AppTheme.red.opacity(0.3), lineWidth: 1))
            }
            .buttonStyle(ScaleButtonStyle())
            .padding(.horizontal, 22)
            .padding(.bottom, 20)
        }
    }

    // MARK: Edit form

    /// Built from the same parts as the create form — amount hero, icon
    /// fields, category tiles, split date and time, one primary button — so
    /// editing a transaction looks and behaves like making one.
    var editForm: some View {
        VStack(spacing: 20) {
            HStack(spacing: 0) {
                ForEach(EditType.allCases, id: \.self) { type in
                    Button {
                        HapticManager.shared.select()
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { editType = type }
                        // Keep category valid for the new type — an expense
                        // category left selected after switching to Income (or
                        // vice-versa) would save a nonsensical pairing.
                        if !availableCategories.contains(editCategory) {
                            editCategory = type == .expense ? .shopping : .salary
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: type.icon).font(.system(.subheadline))
                            Text(type.localizedLabel).font(.system(.subheadline, weight: .semibold))
                        }
                        .foregroundStyle(editType == type ? AppTheme.onVividFill : AppTheme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background {
                            if editType == type {
                                Capsule().fill(type.color)
                            }
                        }
                    }
                }
            }
            .padding(4)
            .background(AppTheme.cardDark, in: Capsule())
            .padding(.horizontal, 22)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    // Currency is locked while editing. The stored amount is IN
                    // this currency, so changing it after the fact would
                    // silently rewrite what hits the card balance.
                    HStack(spacing: 6) {
                        Text(CurrencyManager.symbol(for: editCurrency))
                            .font(.system(.subheadline, weight: .bold))
                            .foregroundStyle(AppTheme.accent)
                        Text(editCurrency)
                            .font(.system(.footnote, weight: .medium))
                        Image(systemName: "lock.fill")
                            .font(.system(.caption2)).imageScale(.small)
                    }
                    .foregroundStyle(AppTheme.textSecondary)
                    .padding(.horizontal, 13).padding(.vertical, 12)
                    .background(AppTheme.cardMid, in: RoundedRectangle(cornerRadius: AppRadius.md))

                    TextField("0", text: $editAmount)
                        .font(.system(.largeTitle, weight: .bold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .keyboardType(.decimalPad)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(14)
                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))

                // Same single helper line as the create form: echo the typed
                // digits back formatted, so a missing zero is caught here.
                if let p = AmountInputHelper.preview(editAmount, currency: editCurrency) {
                    Text(p)
                        .font(.system(.caption, weight: .medium))
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }
            .padding(.horizontal, 22)

            IconField(label: loc("tx.name_label"),
                      icon: "textformat",
                      placeholder: loc("tx.name_placeholder"),
                      text: $editName)
                .padding(.horizontal, 22)

            VStack(alignment: .leading, spacing: 10) {
                FormSectionLabel(text: loc("common.category"))
                    .padding(.horizontal, 22)
                CategoryTilePicker(categories: availableCategories, selection: $editCategory)
            }

            VStack(alignment: .leading, spacing: 10) {
                FormSectionLabel(text: loc("tx.date_time"))
                DateTimeFields(date: $editDate)
            }
            .padding(.horizontal, 22)

            IconField(label: loc("tx.notes"),
                      icon: "text.alignleft",
                      placeholder: loc("tx.notes_placeholder"),
                      text: $editNotes,
                      optionalHint: loc("common.optional"))
                .padding(.horizontal, 22)

            Button { saveEdits() } label: {
                let canSave = (Double(editAmount) ?? 0) > 0
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").font(.system(.body))
                    Text(loc("common.save")).font(.system(.callout, weight: .bold))
                }
                .foregroundStyle(canSave ? AppTheme.onVividFill : AppTheme.textSecondary)
                .frame(maxWidth: .infinity).padding(.vertical, 17)
                .background(canSave ? editType.color : AppTheme.textSecondary.opacity(0.25),
                            in: RoundedRectangle(cornerRadius: AppRadius.lg))
            }
            .buttonStyle(ScaleButtonStyle())
            .disabled((Double(editAmount) ?? 0) <= 0)
            .padding(.horizontal, 22)
            .padding(.top, 4)

            Spacer(minLength: 40)
        }
    }

    private func loadEditState() {
        editName     = tx.name
        // "20000", not "20000.0" — the hero field shows this at 34pt.
        let a = abs(tx.amount)
        editAmount   = a.rounded() == a ? String(Int64(a)) : String(a)
        editCurrency = tx.currency
        editType     = tx.amount >= 0 ? .income : .expense
        editCategory = tx.category
        editDate     = tx.date
        editNotes    = tx.notes
    }

    private func saveEdits() {
        guard let amt = Double(editAmount), amt > 0 else { return }
        tx.name      = editName.trimmingCharacters(in: .whitespaces)
        tx.amount    = editType == .expense ? -abs(amt) : abs(amt)
        tx.currency  = editCurrency
        tx.category  = editCategory
        tx.iconBgHex = editCategory.iconBg
        tx.date      = editDate
        tx.notes     = editNotes
        tx.type      = editType == .expense ? "tx.type.purchase" : "tx.type.income"
        try? context.save()
        HapticManager.shared.success()
        withAnimation { isEditing = false }
    }
}

struct DetailRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label).font(.system(.subheadline)).foregroundStyle(AppTheme.textSecondary)
            Spacer()
            Text(value).font(.system(.subheadline, weight: .medium)).foregroundStyle(AppTheme.textPrimary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }
}

// MARK: - Add Transaction Sheet (updated with IDR/USD)

struct AddTransactionSheet: View {
    let vm: AppViewModel
    var preselectedCategory: TxCategory? = nil
    /// Pre-select a specific card (e.g. "Log a purchase" from a credit card).
    var preselectedCardID: UUID? = nil
    /// Lock the card to `preselectedCardID` so it can't be swiped away. Set by the
    /// credit-card "Log a purchase" entry: that flow exists to record a spend on
    /// THAT card, so letting the user swipe to another card silently logs the
    /// purchase somewhere else. Off for the generic add-transaction entry, where
    /// preselect is only a starting point the user is free to change.
    var lockToPreselectedCard: Bool = false
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var activeDebts: [DebtRecord]
    @Query(sort: \SalarySchedule.createdAt) private var salarySchedules: [SalarySchedule]
    /// Whole history, used to learn how THIS user categorises merchants.
    @Query private var allTransactions: [TxRecord]
    @Query private var allInstallments: [CardInstallment]

    @State private var txType: AddTxType = .expense
    @State private var name: String = ""
    @State private var amountText: String = ""
    @State private var currency: String = CurrencyManager.shared.preferredCurrency
    @State private var selectedCategory: TxCategory = .shopping
    @State private var selectedDate: Date = .now
    @State private var selectedCardIndex: Int = 0
    @State private var selectedDebtID: UUID? = nil
    @State private var notes: String = ""
    @State private var showError = false
    @State private var saveInPreferred = false
    @State private var showBudgetAlert = false
    @State private var pendingBudgetAlert: BudgetAlert? = nil
    @State private var showCreditLimitAlert = false
    @State private var creditOverConfirmed = false
    @State private var showConversionPaywall = false
    /// Receipt scanner moved here from the Home FAB. Royal-only feature; tapping
    /// shows the paywall first when the user lacks access.
    @State private var showScanFlow: Bool = false
    @State private var showScanPaywall: Bool = false
    // Subtype is intentionally NOT a field on the create form — assigning
    // refund/transfer to a brand-new tx without a parent is rare and
    // confusing. Instead, the user creates a normal tx, then taps it in
    // the list to access "Mark as Refund/Transfer" actions where the
    // intent is clear (this existing tx came back / this is a movement).
    // See TransactionDetailSheet's subtypeActions section.
    /// Observe PremiumManager so the currency menu, scan-receipt entry, and
    /// effectiveCurrency/effectiveAmount logic re-render when the user
    /// upgrades/downgrades while this sheet is open. Without this, finishing
    /// a purchase in the paywall presented from inside the sheet leaves the
    /// menu stuck in its locked state — user has to dismiss and re-open.
    @State private var pm = PremiumManager.shared

    private var monthlyIncome: Double {
        // Budget limits are based on STATED monthly income, exactly like the
        // Smart Budget screen ("From salary schedule"). This used to add any
        // extra income logged this calendar month, which silently raised the
        // limit here (Rp 5.057.500) while Smart Budget still showed Rp 5.000.000
        // — two different "budget exceeded" thresholds for the same budget.
        let scheduled = MainCard.salaries(salarySchedules).reduce(0) { $0 + $1.amount }
        if scheduled > 0 { return scheduled }
        // No schedule → fall back to income actually received this month.
        let cal = Calendar.current
        let monthStart = cal.safeDate(from: cal.dateComponents([.year, .month], from: Date()))
        return allCardTransactions
            .filter { $0.amount > 0 && $0.txSubtype != .transfer && $0.date >= monthStart }
            .reduce(0) { $0 + $1.amount }
    }

    private var allCardTransactions: [TxRecord] {
        vm.cards.flatMap { $0.transactions }
    }

    private var preferredCurrency: String { CurrencyManager.shared.preferredCurrency }

    /// Mata uang dari kartu yang sedang dipilih — ini yang jadi acuan konversi,
    /// bukan preferredCurrency global. Bug lama pakai preferredCurrency sehingga
    /// konversi salah ketika kartu punya currency berbeda dari setting user.
    private var selectedCardCurrency: String {
        guard !vm.cards.isEmpty else { return preferredCurrency }
        let card = vm.cards[min(selectedCardIndex, vm.cards.count - 1)]
        return card.currency.isEmpty ? preferredCurrency : card.currency
    }

    /// Bug 2 fix: bandingkan dengan kartu yang dipilih, bukan preferredCurrency.
    /// Sebelumnya: currency != preferredCurrency
    /// Sesudah:    currency != selectedCardCurrency
    /// Efek: panel "Konversi Cerdas" muncul kapanpun mata uang transaksi ≠ kartu.
    private var isForeignCurrency: Bool { currency != selectedCardCurrency }

    /// Bug 1+2 fix: konversi ke mata uang kartu, bukan preferredCurrency.
    private var convertedAmount: Double {
        CurrencyManager.shared.convert(amount, from: currency, to: selectedCardCurrency)
    }

    /// Bug 1 fix: ketika mata uang transaksi berbeda dari kartu, SELALU konversi.
    /// saveInPreferred dipakai hanya ketika currencies sama (sebagai opsional).
    ///
    /// Premium gate (defense-in-depth): if the user lacks Smart Conversion
    /// access, we never trigger the converter at the save layer — even if
    /// `currency` drifted away from `selectedCardCurrency` during a race
    /// between init and onAppear, or via some future code path. The menu
    /// itself is also gated (it shows the paywall instead), so in practice
    /// these branches never differ. This guard is the last line of defense.
    private var effectiveCurrency: String {
        if !PremiumManager.shared.canAccess(.smartConversion) {
            return selectedCardCurrency
        }
        return isForeignCurrency ? selectedCardCurrency : (saveInPreferred ? selectedCardCurrency : currency)
    }
    private var effectiveAmount: Double {
        if !PremiumManager.shared.canAccess(.smartConversion) {
            // Free users have currency forced to card currency above; the
            // typed amount is therefore already in the right unit and needs
            // no conversion.
            return amount
        }
        return isForeignCurrency ? convertedAmount : (saveInPreferred ? convertedAmount : amount)
    }

    /// Bug 3 fix: jumlahkan semua transaksi dengan konversi mata uang yang benar.
    /// Sebelumnya: card.transactions.reduce(0) { $0 + $1.amount } — tidak konversi!
    ///   Kartu IDR dengan tx +5.000.000 IDR dan +1.000 USD → salah jadi 5.001.000.
    /// Sesudah: tiap tx dikonversi ke mata uang kartu sebelum dijumlahkan,
    ///   sama persis dengan liveTransactionBalance() di BankCardHelpers.
    /// A credit card cannot receive income. Money arriving on one is a bill
    /// payment or a refund, which have their own flows — and logging it as
    /// Income here would count toward reported income (StatisticsView sums
    /// `amount > 0`), inflating what the user appears to earn.
    private var selectedIsCredit: Bool { selectedCardOrNil?.isCreditCard == true }

    private var selectedCardOrNil: BankCard? {
        guard !vm.cards.isEmpty else { return nil }
        return vm.cards[min(selectedCardIndex, vm.cards.count - 1)]
    }

    private var selectedCardBalance: Double {
        guard !vm.cards.isEmpty else { return 0 }
        let card = vm.cards[min(selectedCardIndex, vm.cards.count - 1)]
        let cardCur = card.currency.isEmpty ? preferredCurrency : card.currency
        let txBalance = card.transactions.reduce(0.0) { sum, tx in
            sum + CurrencyManager.shared.convert(tx.amount, from: tx.currency, to: cardCur)
        }
        return card.balance + txBalance
    }

    /// Bug 3 fix: bandingkan dalam mata uang kartu secara konsisten.
    /// Sebelumnya: selectedCardBalance (salah) - effectiveAmount (kadang IDR, kadang USD)
    /// Sesudah:    selalu konversi ke selectedCardCurrency sebelum dibandingkan.
    private var wouldGoNegative: Bool {
        guard txType == .expense, amount > 0 else { return false }
        // A credit card holds no cash, so `balance` is meaningless for it —
        // spending room is limit minus what is owed. Blocking here compared
        // the purchase against a leftover cash figure and refused perfectly
        // affordable purchases on a card with millions of rupiah of credit
        // still free. The real ceiling is enforced in `saveTransaction()`,
        // which warns and still lets the user proceed the way an issuer does.
        if let card = selectedCardOrNil, card.isCreditCard { return false }
        let amountInCardCurrency: Double
        if saveInPreferred {
            // sudah dikonversi ke selectedCardCurrency
            amountInCardCurrency = convertedAmount
        } else {
            // konversi amount ke selectedCardCurrency untuk perbandingan
            amountInCardCurrency = CurrencyManager.shared.convert(
                amount, from: currency, to: selectedCardCurrency
            )
        }
        return selectedCardBalance - amountInCardCurrency < 0
    }
    private var availableCategories: [TxCategory] {
        switch txType {
        // `.debtPayment` belongs here. Without it, someone paying off a credit
        // card by hand had no honest option and reached for "Other" — which is
        // how a Rp 1.000.000 debt repayment ended up inside this user's daily
        // spending pattern, month after month. The two menu flows (Debt Tracker
        // and the CC bill screen) always categorised it correctly; the manual
        // path was the one with no right answer.
        case .expense: return [.shopping, .food, .travel, .bills, .transport,
                               .health, .commitment, .investment, .debtPayment, .other]
        case .income:  return [.salary, .freelance, .business, .investment, .bonus, .gift, .incomeOther]
        }
    }

    enum AddTxType: String, CaseIterable {
        case expense
        case income
        
        var title: String {
                switch self {
                case .expense: return loc("tx.expense")
                case .income:  return loc("tx.income")
                }
            }

        /// Used only as a solid fill (the type capsule, the Record button), so
        /// it takes the fill tokens. Reading `AppTheme.red` here is what
        /// dragged the light-mode button from salmon to a hard red when `red`
        /// was darkened for TEXT legibility — a change the fill never needed.
        var color: Color { self == .expense ? AppTheme.redFill : AppTheme.accentFill }
        var icon: String { self == .expense ? "arrow.up.circle.fill" : "arrow.down.circle.fill" }
    }

    var amount: Double { Double(amountText) ?? 0 }
    var isValid: Bool  { !name.trimmingCharacters(in: .whitespaces).isEmpty && amount > 0 }

    @ViewBuilder
    var currencyButtonLabel: some View {
        HStack(spacing: 6) {
            Text(CurrencyManager.symbol(for: currency))
                .font(.system(.subheadline, weight: .bold))
                .foregroundStyle(AppTheme.accent)
            Text(currency)
                .font(.system(.footnote, weight: .medium))
                .foregroundStyle(AppTheme.textSecondary)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(.caption2)).imageScale(.small)
                .foregroundStyle(AppTheme.textSecondary)
        }
        // `cardMid`, not `cardDark`: this pill now sits INSIDE the amount card,
        // and cardDark on cardDark is white on white in light mode.
        .padding(.horizontal, 13).padding(.vertical, 12)
        .background(AppTheme.cardMid, in: RoundedRectangle(cornerRadius: AppRadius.md))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.md).stroke(AppTheme.accent.opacity(0.3), lineWidth: 1))
    }

    var convertedPreview: String {
        guard amount > 0, currency != CurrencyManager.shared.preferredCurrency else { return "" }
        let pref = CurrencyManager.shared.preferredCurrency
        let conv = CurrencyManager.shared.convert(amount, from: currency, to: pref)
        return String(format: loc("tx.converted_in"),
                      CurrencyManager.shared.formatted(conv, currency: pref), pref)
    }

    // MARK: - Form sections
    //
    // `body` used to be one ~560-line expression, and Swift's type checker had
    // started refusing it outright ("unable to type-check this expression in
    // reasonable time") whenever anything else was added. Naming each section
    // fixes that, and it means the order of the form — what the user meets
    // first, second, third — is readable in ten lines instead of six hundred.

    /// Scanning fills the whole form in one shot, so it belongs above the form,
    /// before anyone starts typing a thing they would then have to undo.
    @ViewBuilder
    private var scanEntrySection: some View {
        if !vm.cards.isEmpty && txType == .expense {
            Button {
                HapticManager.shared.tap()
                if PremiumManager.shared.canAccess(.scanReceipt) {
                    showScanFlow = true
                } else {
                    showScanPaywall = true
                }
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: AppRadius.sm)
                            .fill(AppTheme.accent.opacity(0.14))
                            .frame(width: 38, height: 38)
                        Image(systemName: "doc.text.viewfinder")
                            .font(.system(.body, weight: .semibold))
                            .foregroundStyle(AppTheme.accent)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(loc("receipt.entry.title"))
                                .font(.system(.subheadline, weight: .bold))
                                .foregroundStyle(AppTheme.textPrimary)
                            if !PremiumManager.shared.canAccess(.scanReceipt) {
                                Image(systemName: "crown.fill")
                                    .font(.system(.caption2, weight: .bold)).imageScale(.small)
                                    .foregroundStyle(AppTheme.onVividFill)
                                    .padding(3)
                                    .background(PremiumPlan.royal.color, in: Circle())
                            }
                        }
                        Text(loc("receipt.entry.subtitle"))
                            .font(.system(.caption2))
                            .foregroundStyle(AppTheme.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(.caption, weight: .semibold))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .padding(12)
                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
                .overlay(RoundedRectangle(cornerRadius: AppRadius.md)
                    .stroke(AppTheme.accent.opacity(0.22), lineWidth: 1))
            }
            .buttonStyle(ScaleButtonStyle())
            .padding(.horizontal, 22)
        }
    }

    private var typeSection: some View {
        HStack(spacing: 0) {
            ForEach(AddTxType.allCases, id: \.self) { type in
                let blocked = (type == .income && selectedIsCredit)
                Button {
                    HapticManager.shared.select()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { txType = type }
                    if !availableCategories.contains(selectedCategory) {
                        selectedCategory = type == .expense ? .shopping : .salary
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: type.icon).font(.system(.subheadline))
                        Text(type.title).font(.system(.subheadline, weight: .semibold))
                    }
                    .foregroundStyle(txType == type ? AppTheme.onVividFill
                                     : AppTheme.textSecondary.opacity(blocked ? 0.35 : 1))
                    .frame(maxWidth: .infinity).padding(.vertical, 13)
                    .background {
                        if txType == type {
                            Capsule().fill(type.color)
                        }
                    }
                }
                .disabled(blocked)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: txType)
            }
        }
        .padding(4)
        .background(AppTheme.cardDark, in: Capsule())
        .padding(.horizontal, 22)
    }

    /// The amount is the reason this screen exists, so it gets the largest type
    /// on it and shares a single surface with the currency it is denominated in
    /// — the two were previously separate boxes, which read as two questions.
    @ViewBuilder
    private var amountSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                if PremiumManager.shared.canAccess(.smartConversion) {
                    Menu {
                        ForEach(CurrencyManager.supportedCurrencies, id: \.code) { c in
                            Button {
                                HapticManager.shared.tap()
                                currency = c.code
                            } label: {
                                Label("\(c.flag) \(c.code) — \(c.name)",
                                      systemImage: currency == c.code ? "checkmark" : "")
                            }
                        }
                    } label: {
                        currencyButtonLabel
                    }
                } else {
                    Button { HapticManager.shared.tap(); showConversionPaywall = true } label: {
                        currencyButtonLabel
                            .overlay(alignment: .topTrailing) {
                                Image(systemName: "lock.fill")
                                    .font(.system(.caption2, weight: .bold)).imageScale(.small)
                                    .foregroundStyle(AppTheme.onVividFill)
                                    .padding(3)
                                    .background(PremiumPlan.royal.color, in: Circle())
                                    .offset(x: 4, y: -4)
                            }
                    }
                    .buttonStyle(.plain)
                }

                TextField("0", text: $amountText)
                    .font(.system(.largeTitle, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .keyboardType(.decimalPad)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))

            // One quiet line under the field, not three. Whichever of these is
            // true is the one worth reading: a cross-currency result beats a
            // formatting echo, and both beat the bare rate.
            Group {
                if !convertedPreview.isEmpty {
                    Text(convertedPreview)
                        .font(.system(.caption))
                        .foregroundStyle(AppTheme.textSecondary)
                } else if let p = AmountInputHelper.preview(amountText, currency: currency) {
                    // Echo "5000000" back as "Rp 5.000.000" so a digit-count
                    // typo is caught before it is saved, not after.
                    Text(p)
                        .font(.system(.caption, weight: .medium))
                        .foregroundStyle(AppTheme.textSecondary)
                } else {
                    Text(CurrencyManager.shared.rateLabel)
                        .font(.system(.caption2))
                        .foregroundStyle(AppTheme.textSecondary.opacity(0.7))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if amount > 0 && isForeignCurrency {
                conversionPanel
            }
        }
        .padding(.horizontal, 22)
    }

    private var conversionPanel: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(AppTheme.accent.opacity(0.12)).frame(width: 36, height: 36)
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(AppTheme.accent)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(loc("tx.smart_convert"))
                        .font(.system(.footnote, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(String(format: loc("tx.save_in_currency"), selectedCardCurrency))
                        .font(.system(.caption2))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                Spacer()
                // Locked ON: a transaction in a currency the card does not hold
                // MUST be converted, or the balance stops meaning anything.
                Text(loc("tx.required"))
                    .font(.system(.caption2, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(AppTheme.accent.opacity(0.12), in: Capsule())
            }

            if saveInPreferred {
                Divider().background(AppTheme.cardMid)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(loc("tx.you_entered"))
                            .font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
                        Text(CurrencyManager.shared.formatted(amount, currency: currency))
                            .font(.system(.subheadline, weight: .semibold)).foregroundStyle(AppTheme.textSecondary)
                    }
                    Image(systemName: "arrow.right")
                        .font(.system(.caption)).foregroundStyle(AppTheme.accent)
                        .padding(.horizontal, 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(loc("tx.saved_as"))
                            .font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
                        Text(CurrencyManager.shared.formatted(convertedAmount, currency: selectedCardCurrency))
                            .font(.system(.subheadline, weight: .bold)).foregroundStyle(AppTheme.accent)
                    }
                    Spacer()
                }
                Text(CurrencyManager.shared.rateLabel)
                    .font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary.opacity(0.6))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .background(AppTheme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: AppRadius.md))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.md)
            .stroke(AppTheme.accent.opacity(saveInPreferred ? 0.4 : 0.15), lineWidth: 1))
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: saveInPreferred)
    }

    @ViewBuilder
    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            IconField(label: loc("tx.name_label"),
                      icon: "textformat",
                      placeholder: selectedCategory == .debtPayment
                          ? loc("tx.debt_placeholder")
                          : loc("tx.name_placeholder"),
                      text: $name)
                .onChange(of: name) { _, newName in
                    // The user's own history first, the shipped keyword map
                    // second — what this person actually does beats a guess.
                    if txType == .expense,
                       let suggested = CategorySuggestionHint.autoPick(
                            for: newName, transactions: allTransactions,
                            categories: availableCategories) {
                        // Without animation: this follows the typing keystroke
                        // by keystroke, and a spring on every guess set tiles,
                        // labels and the hint line moving under the words the
                        // user was still writing.
                        selectedCategory = suggested
                    }
                }

            if txType == .expense {
                CategorySuggestionHint(name: name, transactions: allTransactions,
                                       categories: availableCategories,
                                       selection: $selectedCategory)
            }
        }
        .padding(.horizontal, 22)
    }

    private var categorySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            FormSectionLabel(text: loc("common.category"))
                .padding(.horizontal, 22)
            CategoryTilePicker(categories: availableCategories, selection: $selectedCategory)
        }
    }

    /// Always shown, even with a single card: "which account does this land
    /// on" is worth answering before saving, not only when there is a choice.
    @ViewBuilder
    private var cardSection: some View {
        if !vm.cards.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                FormSectionLabel(text: loc("debt.card"))
                    .padding(.horizontal, 22)
                // For a credit card the face states the room left on the limit,
                // not what is owed — at the moment of spending, that is the
                // number that matters.
                CardSwipePicker(cards: vm.cards, selectedIndex: $selectedCardIndex,
                                locked: lockToPreselectedCard) { card in
                    card.isCreditCard
                        ? (loc("cc.available"),
                           CurrencyManager.shared.formatted(card.availableCredit(allInstallments),
                                                            currency: card.resolvedCurrency))
                        : (loc("home.balance_total"), card.formattedBalance)
                }
                // Say WHY the card can't be changed here, so a locked picker reads
                // as intentional rather than broken.
                if lockToPreselectedCard {
                    Label(loc("tx.card_locked_cc"), systemImage: "lock.fill")
                        .font(.system(.caption2))
                        .foregroundStyle(AppTheme.textSecondary)
                        .padding(.horizontal, 22)
                }
            }
        }
    }

    private var dateSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            FormSectionLabel(text: loc("tx.date_time"))
            DateTimeFields(date: $selectedDate)
        }
        .padding(.horizontal, 22)
    }

    private var notesSection: some View {
        IconField(label: loc("tx.notes"),
                  icon: "text.alignleft",
                  placeholder: loc("tx.notes_placeholder"),
                  text: $notes,
                  optionalHint: loc("common.optional"))
            .padding(.horizontal, 22)
    }

    @ViewBuilder
    private var warningSection: some View {
        let negative = wouldGoNegative && !vm.cards.isEmpty && txType == .expense
        // Guarded as a whole. An empty VStack still counts as a child, so the
        // parent's 20pt spacing landed on both sides of nothing.
        if selectedIsCredit || vm.cards.isEmpty || negative || showError {
        VStack(spacing: 10) {
            // A disabled control with no explanation reads as a bug. Name the
            // reason, and point at the flow that does handle money arriving on
            // a credit card.
            if selectedIsCredit {
                InlineBanner(tone: .info, message: loc("tx.credit_no_income"))
            }
            if vm.cards.isEmpty {
                InlineBanner(tone: .warning, message: loc("common.add_card_tx"))
            }
            if wouldGoNegative && !vm.cards.isEmpty && txType == .expense {
                let msg = loc("tx.insufficient") + "\n"
                    + String(format: loc("tx.available_balance"),
                             CurrencyManager.shared.formatted(Swift.abs(selectedCardBalance),
                                                              currency: selectedCardCurrency))
                InlineBanner(tone: .error, message: msg)
            }
            if showError {
                InlineBanner(tone: .error, message: loc("tx.valid_error"))
            }
        }
        .padding(.horizontal, 22)
        }
    }

    private var submitSection: some View {
        // No Cancel under Save: the toolbar already has one, and a second exit
        // a thumb's width below the primary action is a mis-tap waiting to
        // throw away a filled-in form.
        VStack(spacing: 6) {
            Button { saveTransaction() } label: {
                // Computed once for both fill and label: the old code styled the
                // label `AppTheme.bg` unconditionally, so a disabled button was
                // light text on a light grey fill — effectively invisible.
                let canSubmit = isValid && !(wouldGoNegative && txType == .expense)
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").font(.system(.body))
                    Text(String(format: loc("tx.add_type"), txType.title))
                        .font(.system(.callout, weight: .bold))
                }
                .foregroundStyle(canSubmit ? AppTheme.onVividFill : AppTheme.textSecondary)
                .frame(maxWidth: .infinity).padding(.vertical, 17)
                .background(canSubmit ? txType.color : AppTheme.textSecondary.opacity(0.25),
                            in: RoundedRectangle(cornerRadius: AppRadius.lg))
            }
            .buttonStyle(ScaleButtonStyle())
            .disabled(!isValid || vm.cards.isEmpty || (wouldGoNegative && txType == .expense))
        }
        .padding(.horizontal, 22)
        .padding(.top, 4)
    }

    var body: some View {
        // Touch pm.plan so SwiftUI's @Observable tracking registers this body
        // as a dependent of PremiumManager.shared. After a successful upgrade
        // the body re-evaluates and the locked currency-menu / scan-receipt
        // entry refresh without needing the user to re-open the sheet.
        let _ = pm.plan
        return NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {
                        scanEntrySection
                        typeSection
                        amountSection
                        nameSection
                        categorySection
                        cardSection
                        dateSection
                        notesSection
                        warningSection
                        submitSection

                        Spacer(minLength: 40)
                    }
                    .padding(.top, 6)
                    .containerRelativeFrame(.horizontal)
                    // No entrance animation. The sheet already carries the form
                    // up; fading and lifting the content inside it as well made
                    // every label drift into place a beat after the sheet had
                    // landed, which read as the screen glitching, not as polish.
                    // Content arriving is not a change the user caused, and
                    // AppMotion reserves motion for those.
                    // These two were previously attached to the card picker and
                    // so only ran when the user owned more than one card. The
                    // currency rule is not about how many cards exist.
                    .onChange(of: selectedCardIndex) { _, i in
                        guard i < vm.cards.count else { return }
                        let card = vm.cards[i]
                        currency = card.currency.isEmpty
                            ? CurrencyManager.shared.preferredCurrency
                            : card.currency
                        saveInPreferred = false   // a newly picked card matches its own currency
                        // Switching to a credit card while Income is selected
                        // would leave the form on a type its own picker now
                        // refuses to let you select.
                        if card.isCreditCard, txType == .income {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                txType = .expense
                            }
                            if !availableCategories.contains(selectedCategory) {
                                selectedCategory = .shopping
                            }
                        }
                    }
                    .onChange(of: currency) { _, newCur in
                        // Without this a USD amount could be saved onto an IDR
                        // card unconverted, and the balance stops adding up.
                        withAnimation(.spring(response: 0.3)) {
                            saveInPreferred = newCur != selectedCardCurrency
                        }
                    }
                }
            }
            .navigationTitle(loc("tx.new"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc("common.cancel")) { HapticManager.shared.tap(); dismiss() }
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }
        }
        .onAppear {
            CurrencyManager.shared.fetchRate()
            // Start on the card the user was viewing on home, or a specific
            // card if the caller asked for one (e.g. "Log a purchase" on a CC).
            if let id = preselectedCardID, let idx = vm.cards.firstIndex(where: { $0.id == id }) {
                selectedCardIndex = idx
            } else {
                selectedCardIndex = min(vm.selectedCardIndex, max(vm.cards.count - 1, 0))
            }
            // Init currency from that card
            if !vm.cards.isEmpty {
                let card = vm.cards[min(selectedCardIndex, vm.cards.count - 1)]
                let cardCur = card.currency.isEmpty ? CurrencyManager.shared.preferredCurrency : card.currency
                currency = cardCur
            }
            if let pre = preselectedCategory {
                selectedCategory = pre
                if pre == .debtPayment { txType = .expense }
            }
        }
        .sheet(isPresented: $showConversionPaywall) {
            PaywallView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
                .preferredColorScheme(appColorScheme())
        }
        // Receipt scan flow — full screen so the camera has the whole canvas.
        // We pass the currently-selected card's currency so the parser can
        // disambiguate ambiguous amounts (e.g., "150" → IDR vs USD).
        .fullScreenCover(isPresented: $showScanFlow) {
            ReceiptScanFlow(
                cardCurrency: selectedCardCurrency,
                onCompleted: {
                    // Scan flow saved the tx directly. Dismiss the parent
                    // AddTransactionSheet so the user lands back on Home with
                    // the new tx visible.
                    dismiss()
                }
            )
            .preferredColorScheme(appColorScheme())
        }
        .sheet(isPresented: $showScanPaywall) {
            PaywallView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
                .preferredColorScheme(appColorScheme())
        }
        .confirmSheet(isPresented: $showBudgetAlert,
                      icon: pendingBudgetAlert?.isExceeded == true
                          ? "exclamationmark.triangle.fill" : "gauge.with.dots.needle.67percent",
                      tone: .warning,
                      title: pendingBudgetAlert?.isExceeded == true
                          ? loc("tx.budget_exceed") : loc("tx.approach_limit"),
                      message: budgetAlertMessage,
                      confirmLabel: loc("tx.add_anyway")) { commitTransaction() }
        .confirmSheet(isPresented: $showCreditLimitAlert,
                      icon: "creditcard.trianglebadge.exclamationmark",
                      tone: .warning,
                      title: loc("cc.over_limit_title"),
                      message: creditOverMessage,
                      confirmLabel: loc("tx.add_anyway")) {
            creditOverConfirmed = true
            saveTransaction()
        }
        .trackScreen(.addTransaction)
    }

    private var budgetAlertMessage: String {
        guard let alert = pendingBudgetAlert else { return "" }
        let pref = CurrencyManager.shared.preferredCurrency
        if alert.isExceeded {
            return String(format: loc("tx.budget_over_msg"), alert.displayLabel.lowercased(),
                          CurrencyManager.shared.formatted(alert.over, currency: pref),
                          CurrencyManager.shared.formatted(alert.limit, currency: pref))
        }
        return String(format: loc("tx.budget_approach_msg"), alert.displayLabel.lowercased(),
                      CurrencyManager.shared.formatted(alert.limit, currency: pref),
                      CurrencyManager.shared.formatted(alert.limit - alert.spent, currency: pref))
    }

    private var creditOverMessage: String {
        guard vm.cards.indices.contains(selectedCardIndex) else { return "" }
        let card = vm.cards[selectedCardIndex]
        return String(format: loc("cc.over_limit_msg"),
                      CurrencyManager.shared.formatted(card.availableCredit(allInstallments),
                                                       currency: card.resolvedCurrency))
    }

    private func saveTransaction() {
        guard isValid else { HapticManager.shared.error(); withAnimation { showError = true }; return }
        guard !vm.cards.isEmpty else {
            HapticManager.shared.error(); withAnimation { showError = true }; return
        }

        // Credit-limit check — spending on a credit card that would blow past
        // its limit. Warns once; "Add anyway" proceeds (issuers do allow small
        // over-limit spend). Only for expenses on a credit card.
        if txType == .expense, vm.cards.indices.contains(selectedCardIndex) {
            let card = vm.cards[selectedCardIndex]
            if card.isCreditCard, card.creditLimit > 0, !creditOverConfirmed {
                let addInCardCur = CurrencyManager.shared.convert(abs(effectiveAmount), from: effectiveCurrency, to: card.resolvedCurrency)
                // `totalOwed` counts instalment principal; `owedBalance()` does
                // not, so this used to let a purchase through that the card had
                // no room for once running instalments were taken into account.
                if card.totalOwed(allInstallments) + addInCardCur > card.creditLimit {
                    showCreditLimitAlert = true
                    HapticManager.shared.warning()
                    return
                }
            }
        }

        // Smart budget check — only for expenses
        if txType == .expense {
            // Pay-cycle scoped, matching the Smart Budget screen — a calendar
            // month window understates spend before payday, so the "this will
            // exceed your budget" warning wouldn't fire even when already over.
            let cycleStart: Date? = salarySchedules.first(where: { $0.isActive })
                .map { StatPeriod.payCycleRange(payDay: $0.dayOfMonth).start }
            if let alert = SmartBudgetManager.shared.wouldExceed(
                category: selectedCategory,
                amount: effectiveAmount,
                transactions: allCardTransactions,
                income: monthlyIncome,
                periodStart: cycleStart
            ) {
                pendingBudgetAlert = alert
                showBudgetAlert = true
                HapticManager.shared.warning()
                return
            }
        }

        commitTransaction()
    }

    private func commitTransaction() {
        let finalAmount = txType == .expense ? -abs(effectiveAmount) : abs(effectiveAmount)
        // Stable keys stored in DB — never loc() at creation time.
        // TransactionDetailSheet renders via tx.displayType which translates at display time.
        let txType_str  = selectedCategory == .debtPayment ? "tx.type.debt_payment"
                        : txType == .expense ? "tx.type.purchase" : "tx.type.income"

        let record = TxRecord(
            name: name.trimmingCharacters(in: .whitespaces),
            date: selectedDate, amount: finalAmount,
            type: txType_str,
            icon: String(name.prefix(2).uppercased()),
            iconBgHex: selectedCategory.iconBg,
            category: selectedCategory, currency: effectiveCurrency, notes: notes
            // subtype defaults to .normal at the model level — refund/transfer
            // are assigned later via TransactionDetailSheet's "Mark as ..."
            // actions, where the intent (this past tx came back / is a
            // transfer) makes sense in context.
        )
        vm.cards[selectedCardIndex].transactions.append(record)
        // Confirm the RESULT, not just "saved" — the amount and where it went.
        ActionFeedbackCenter.shared.transactionSaved(
            amount: record.amount, currency: record.currency,
            category: record.category,
            cardLabel: vm.cards[selectedCardIndex].pickerLabel)

        // Auto-reduce linked debt balance.
        // Convert the payment amount into the debt's currency before
        // subtracting. Without this, paying a USD-denominated debt with an
        // IDR card would subtract 750_000 (IDR) directly from a $1_000 USD
        // balance — wiping the debt incorrectly. We use effectiveAmount/
        // effectiveCurrency (i.e., what was actually written to the tx
        // record) so the deduction stays consistent with the saved tx.
        if selectedCategory == .debtPayment,
           let debtID = selectedDebtID,
           let debt = activeDebts.first(where: { $0.id == debtID }) {
            let paidInDebtCurrency = CurrencyManager.shared.convert(
                abs(effectiveAmount), from: effectiveCurrency, to: debt.currency
            )
            debt.currentBalance = max(debt.currentBalance - paidInDebtCurrency, 0)
            if debt.currentBalance == 0 {
                debt.isActive = false
                HapticManager.shared.rigidImpact()
            }
        }

        try? context.save()
        HapticManager.shared.success()
        dismiss()
    }
}

// MARK: - Custom Date Range Sheet

struct CustomDateRangeSheet: View {
    @Binding var startDate: Date
    @Binding var endDate: Date
    @Environment(\.dismiss) private var dismiss

    @State private var localStart: Date = Date()
    @State private var localEnd: Date = Date()

    var body: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 3)
                .fill(AppTheme.cardMid)
                .frame(width: 36, height: 4)
                .padding(.top, 12)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(loc("tx.custom_range"))
                        .font(.system(.body, weight: .bold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(loc("tx.max_range"))
                        .font(.system(.caption))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.top, 16)

            VStack(spacing: 16) {
                VStack(spacing: 6) {
                    Text(loc("tx.start_date"))
                        .font(.system(.footnote)).foregroundStyle(AppTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    DatePicker("", selection: $localStart, in: ...Date(), displayedComponents: .date)
                        .datePickerStyle(.compact).labelsHidden().tint(AppTheme.accent)
                        .environment(\.locale, LanguageManager.shared.currentLocale)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onChange(of: localStart) { _, newStart in
                            let maxEnd = Calendar.current.safeDate(byAdding: .month, value: 1, to: newStart)
                            if localEnd > maxEnd { localEnd = maxEnd }
                            if localEnd < newStart { localEnd = newStart }
                        }
                }

                VStack(spacing: 6) {
                    Text(loc("tx.end_date"))
                        .font(.system(.footnote)).foregroundStyle(AppTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    let maxEnd = Calendar.current.safeDate(byAdding: .month, value: 1, to: localStart)
                    DatePicker("", selection: $localEnd,
                               in: localStart...min(maxEnd, Date()), displayedComponents: .date)
                        .datePickerStyle(.compact).labelsHidden().tint(AppTheme.accent)
                        .environment(\.locale, LanguageManager.shared.currentLocale)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                let days = max(Calendar.current.dateComponents([.day], from: localStart, to: localEnd).day ?? 0, 0)
                HStack(spacing: 8) {
                    Image(systemName: "calendar.badge.clock").font(.system(.footnote)).foregroundStyle(AppTheme.accent)
                    Text(days == 1 ? String(format: loc("search.day_results"), days) : String(format: loc("search.days_results"), days))
                        .font(.system(.footnote, weight: .medium)).foregroundStyle(AppTheme.textSecondary)
                    Spacer()
                }
                .padding(12)
                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.sm))
            }
            .padding(.horizontal, 22).padding(.top, 20)

            Spacer()

            Button {
                startDate = Calendar.current.startOfDay(for: localStart)
                var comps = Calendar.current.dateComponents([.year, .month, .day], from: localEnd)
                comps.hour = 23; comps.minute = 59; comps.second = 59
                endDate = Calendar.current.date(from: comps) ?? localEnd
                HapticManager.shared.success()
                dismiss()
            } label: {
                Text(loc("tx.apply_range"))
                    .font(.system(.callout, weight: .bold)).foregroundStyle(AppTheme.bg)
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                    .background(AppTheme.accentFill, in: RoundedRectangle(cornerRadius: AppRadius.lg))
            }
            .buttonStyle(ScaleButtonStyle())
            .padding(.horizontal, 22).padding(.bottom, 32)
        }
        .onAppear { localStart = startDate; localEnd = endDate }
    }
}
