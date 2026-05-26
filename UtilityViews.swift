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

        case .yesterday_period:
            let start = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now))!
            return (start, cal.startOfDay(for: now))

        case .week_period:
            let start = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))!
            return (start, now)

        case .month_period:
            return (cal.date(byAdding: .month, value: -1, to: now)!, now)

        case .three_month_period:
            return (cal.date(byAdding: .month, value: -3, to: now)!, now)

        case .year_period:
            let start = cal.date(from: cal.dateComponents([.year], from: now))!
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
        let locale = LanguageManager.shared.currentLocale
        var dict: [Date: [TxRecord]] = [:]
        for tx in filtered {
            let day = cal.startOfDay(for: tx.date)
            dict[day, default: []].append(tx)
        }
        return dict.keys.sorted(by: >).map { day in
            let label: String
            if cal.isDateInToday(day)          { label = loc("common.today") }
            else if cal.isDateInYesterday(day) { label = loc("common.yesterday") }
            else {
                let weekAgo = cal.safeDate(byAdding: .day, value: -7, to: Date())
                let df = DateFormatter()
                df.locale = locale
                if day >= weekAgo {
                    df.dateFormat = DateFormatter.dateFormat(fromTemplate: "EEEE", options: 0, locale: locale)
                } else {
                    df.dateFormat = DateFormatter.dateFormat(fromTemplate: "d MMMM yyyy", options: 0, locale: locale)
                }
                label = df.string(from: day)
            }
            return (label: label, date: day, txs: (dict[day] ?? []).sorted { $0.date > $1.date })
        }
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
                                .font(.system(size: 16))
                                .foregroundStyle(AppTheme.textSecondary)
                            TextField(loc("search.placeholder"), text: $query)
                                .font(.system(size: 16))
                                .foregroundStyle(AppTheme.textPrimary)
                                .focused($focused)
                                .autocorrectionDisabled()
                            if !query.isEmpty {
                                Button { query = "" } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 16))
                                        .foregroundStyle(AppTheme.textSecondary)
                                }
                            }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 12)
                        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14)
                            .stroke(focused ? AppTheme.accent.opacity(0.5) : Color.clear, lineWidth: 1.5))

                        Button(loc("common.cancel")) { HapticManager.shared.tap(); dismiss() }
                            .foregroundStyle(AppTheme.textSecondary).font(.system(size: 15))
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
                                                .font(.system(size: 10, weight: .medium))
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
                                                .font(.system(size: 12, weight: .semibold))
                                        } else {
                                            Text(period.title)
                                                .font(.system(size: 12, weight: selectedPeriod == period ? .semibold : .regular))
                                        }
                                    }
                                    .foregroundStyle(selectedPeriod == period ? AppTheme.bg : AppTheme.textSecondary)
                                    .padding(.horizontal, 12).padding(.vertical, 7)
                                    .background(selectedPeriod == period ? AppTheme.accent : AppTheme.cardDark, in: Capsule())
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
                                .font(.system(size: 15)).foregroundStyle(AppTheme.textSecondary)
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
                                        .font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
                                    Spacer()
                                    Text(totalAmount >= 0
                                         ? "+\(CurrencyManager.shared.formatted(totalAmount, currency: filtered.first?.currency ?? CurrencyManager.shared.preferredCurrency))"
                                         : CurrencyManager.shared.formatted(totalAmount, currency: filtered.first?.currency ?? CurrencyManager.shared.preferredCurrency))
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(totalAmount >= 0 ? AppTheme.accent : AppTheme.red)
                                }
                                .padding(.horizontal, 22).padding(.vertical, 12)

                                // Grouped results
                                VStack(spacing: 20) {
                                    ForEach(grouped, id: \.date) { group in
                                        VStack(alignment: .leading, spacing: 8) {
                                            // Group header
                                            let groupTotal = group.txs.reduce(0) { $0 + $1.amount }
                                            HStack {
                                                Text(group.label)
                                                    .font(.system(size: 13, weight: .semibold))
                                                    .foregroundStyle(AppTheme.textSecondary)
                                                Spacer()
                                                Text(groupTotal >= 0
                                                     ? "+\(CurrencyManager.shared.formatted(groupTotal, currency: group.txs.first?.currency ?? CurrencyManager.shared.preferredCurrency))"
                                                     : CurrencyManager.shared.formatted(groupTotal, currency: group.txs.first?.currency ?? CurrencyManager.shared.preferredCurrency))
                                                    .font(.system(size: 12, weight: .medium))
                                                    .foregroundStyle(groupTotal >= 0 ? AppTheme.accent.opacity(0.8) : AppTheme.red.opacity(0.8))
                                            }
                                            .padding(.horizontal, 22)

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
                                            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 16))
                                            .padding(.horizontal, 22)
                                        }
                                    }
                                }
                                .padding(.bottom, 40)
                            }
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
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(hex: tx.iconBgHex))
                    .frame(width: 42, height: 42)
                Text(tx.icon)
                    .font(.system(size: tx.icon.count == 1 ? 15 : 18))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(tx.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(AppTheme.textPrimary)
                HStack(spacing: 6) {
                    Text(formattedDate)
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.textSecondary)
                    Text(tx.category.shortLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(tx.category.color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(tx.category.color.opacity(0.12), in: Capsule())
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(CurrencyManager.shared.formatted(abs(tx.amount), currency: tx.currency))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tx.amount >= 0 ? AppTheme.green : AppTheme.textPrimary)
                if tx.amount >= 0 {
                    Text(loc("home.income")).font(.system(size: 10)).foregroundStyle(AppTheme.textSecondary)
                } else {
                    Text(tx.displayType).font(.system(size: 10)).foregroundStyle(AppTheme.textSecondary)
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
    @State private var showDeleteConfirm = false
    
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
        var color: Color { self == .expense ? AppTheme.red : AppTheme.accent }

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

    private var availableCategories: [TxCategory] {
        TxCategory.allCases
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
                    if isEditing {
                        Button(loc("common.save")) { saveEdits() }
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(AppTheme.accent)
                    } else {
                        Button {
                            loadEditState()
                            withAnimation { isEditing = true }
                        } label: {
                            Image(systemName: "pencil")
                                .foregroundStyle(AppTheme.accent)
                        }
                    }
                }
            }
        }
        .confirmationDialog(loc("tx.delete_prompt"), isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button(loc("common.delete"), role: .destructive) {
                context.delete(tx)
                try? context.save()
                HapticManager.shared.warning()
                dismiss()
            }
            Button(loc("common.cancel"), role: .cancel) {}
        } message: {
            Text(loc("tx.delete_confirm"))
        }
    }

    // MARK: Detail view

    var detailView: some View {
        VStack(spacing: 20) {
            // Amount hero
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(Color(hex: tx.iconBgHex))
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
                            .font(.system(size: 10, weight: .semibold))
                        Text(tx.txSubtype.displayLabel)
                            .font(.system(size: 11, weight: .bold))
                    }
                    .foregroundStyle(AppTheme.orange)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(AppTheme.orange.opacity(0.15), in: Capsule())
                    .overlay(Capsule().stroke(AppTheme.orange.opacity(0.3), lineWidth: 1))
                }

                Text(tx.amount >= 0 ? "+\(formattedAmount)" : "-\(formattedAmount)")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(tx.amount >= 0 ? AppTheme.green : AppTheme.red)

                Text(convertedLabel)
                    .font(.system(size: 14))
                    .foregroundStyle(AppTheme.textSecondary)

                if CurrencyManager.shared.isLoading {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.7).tint(AppTheme.textSecondary)
                        Text(loc("common.updating_rate")).font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
                    }
                } else if let updated = CurrencyManager.shared.lastUpdated {
                    Text(String(format: loc("common.rate_as_of"),
                                CurrencyManager.shared.rateLabel,
                                Self.shortTimeString(from: updated)))
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }
            .padding(.top, 16)

            // Details card
            VStack(spacing: 0) {
                DetailRow(label: loc("common.name"), value: tx.name)
                Divider().background(AppTheme.cardMid).padding(.horizontal, 18)
                DetailRow(label: loc("common.date"), value: tx.displayDate)
                Divider().background(AppTheme.cardMid).padding(.horizontal, 18)
                DetailRow(label: loc("common.category"), value: tx.category.displayLabel)
                Divider().background(AppTheme.cardMid).padding(.horizontal, 18)
                DetailRow(label: loc("common.type"), value: tx.displayType)
                Divider().background(AppTheme.cardMid).padding(.horizontal, 18)
                DetailRow(label: loc("common.currency"), value: tx.currency)
                if !tx.notes.isEmpty {
                    Divider().background(AppTheme.cardMid).padding(.horizontal, 18)
                    DetailRow(label: loc("common.notes"), value: tx.displayNotes)
                }
            }
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 18))
            .padding(.horizontal, 22)

            // Subtype actions — only for expense tx since refund/transfer
            // semantics don't apply to income (a refund of income doesn't
            // make sense, and inter-account transfers are usually logged as
            // expense tx pairs anyway).
            if tx.amount < 0 {
                subtypeActions
                    .padding(.horizontal, 22)
            }

            // Delete button
            Button {
                HapticManager.shared.warning()
                showDeleteConfirm = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "trash").font(.system(size: 16))
                    Text(loc("tx.delete")).font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(AppTheme.red)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(AppTheme.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(AppTheme.red.opacity(0.3), lineWidth: 1))
            }
            .buttonStyle(ScaleButtonStyle())
            .padding(.horizontal, 22)
            .padding(.bottom, 20)
        }
    }

    // MARK: - Subtype actions
    //
    // "Mark as Refund / Transfer" actions for an existing tx. This is the
    // primary way users assign a subtype — at create time the picker felt
    // out of place ("am I logging a brand-new refund?"), but here the
    // semantic is clean: "this past tx came back / was a transfer".
    //
    // Layout: when subtype = .normal, show two equal-weight buttons (Refund
    // + Transfer). When already non-normal, show the badge + a single
    // "Reset to Normal" button so user can undo.
    @ViewBuilder
    private var subtypeActions: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.uturn.backward.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.textSecondary)
                Text(loc("tx.subtype.section_title"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)
                Spacer()
            }

            if tx.txSubtype == .normal {
                Text(loc("tx.subtype.section_hint"))
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.textSecondary.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 10) {
                    subtypeButton(
                        for: .refund,
                        title: loc("tx.subtype.mark_refund"),
                        subtitle: loc("tx.subtype.mark_refund_hint")
                    )
                    subtypeButton(
                        for: .transfer,
                        title: loc("tx.subtype.mark_transfer"),
                        subtitle: loc("tx.subtype.mark_transfer_hint")
                    )
                }
            } else {
                // Already marked — show explanation + reset button.
                Text(currentSubtypeExplanation)
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.textSecondary.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    HapticManager.shared.tap()
                    tx.txSubtype = .normal
                    try? context.save()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 13, weight: .semibold))
                        Text(loc("tx.subtype.reset"))
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(AppTheme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppTheme.cardMid, lineWidth: 1))
                }
                .buttonStyle(ScaleButtonStyle())
            }
        }
    }

    /// Compact "Mark as X" button used inside the subtypeActions HStack.
    @ViewBuilder
    private func subtypeButton(for subtype: TxSubtype, title: String, subtitle: String) -> some View {
        Button {
            HapticManager.shared.tap()
            tx.txSubtype = subtype
            try? context.save()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: subtype.icon)
                        .font(.system(size: 13, weight: .semibold))
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                }
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(AppTheme.textSecondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
            }
            .foregroundStyle(AppTheme.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(AppTheme.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppTheme.orange.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(ScaleButtonStyle())
    }

    /// Loc string explaining what the current subtype means for budgeting.
    /// Drives the explanation text that appears above the Reset button when
    /// a tx is already marked non-normal.
    private var currentSubtypeExplanation: String {
        switch tx.txSubtype {
        case .normal:   return ""
        case .refund:   return loc("tx.subtype.refund_explainer")
        case .transfer: return loc("tx.subtype.transfer_explainer")
        }
    }

    // MARK: Edit form

    var editForm: some View {
        VStack(spacing: 20) {
            // Type picker
            HStack(spacing: 0) {
                ForEach(EditType.allCases, id: \.self) { type in
                    Button {
                        HapticManager.shared.tap()
                        withAnimation(.spring(response: 0.3)) { editType = type }
                    } label: {
                        Text(type.localizedLabel)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(editType == type ? AppTheme.bg : AppTheme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background { if editType == type { Capsule().fill(type.color) } }
                    }
                }
            }
            .padding(4)
            .background(AppTheme.cardDark, in: Capsule())
            .padding(.horizontal, 22)

            // Amount + currency
            VStack(spacing: 8) {
                Text(loc("common.amount")).font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22)
                HStack(spacing: 10) {
                    // Currency toggle
                    Button {
                        HapticManager.shared.tap()
                        let p = CurrencyManager.shared.preferredCurrency; editCurrency = editCurrency == p ? "USD" : p
                    } label: {
                        Text(editCurrency)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(AppTheme.accent)
                            .padding(.horizontal, 14).padding(.vertical, 14)
                            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12)
                                .stroke(AppTheme.accent.opacity(0.3), lineWidth: 1))
                    }
                    .buttonStyle(ScaleButtonStyle())

                    TextField("0.00", text: $editAmount)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .keyboardType(.decimalPad)
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 22)

                // Conversion preview
                if let amt = Double(editAmount), amt > 0 {
                    let pref2 = CurrencyManager.shared.preferredCurrency
                    let other = editCurrency == pref2 ? "USD" : pref2
                    let conv  = CurrencyManager.shared.convert(amt, from: editCurrency, to: other)
                    Text("= \(CurrencyManager.shared.formatted(conv, currency: other))")
                        .font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22)
                }
            }

            SheetField(label: "Name", placeholder: "Transaction name", text: $editName)

            // Category
            VStack(spacing: 8) {
                Text(loc("common.category")).font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(availableCategories, id: \.self) { cat in
                            Button {
                                HapticManager.shared.tap()
                                editCategory = cat
                            } label: {
                                Text(cat.rawValue)
                                    .font(.system(size: 13, weight: editCategory == cat ? .semibold : .regular))
                                    .foregroundStyle(editCategory == cat ? AppTheme.bg : AppTheme.textSecondary)
                                    .padding(.horizontal, 14).padding(.vertical, 8)
                                    .background(editCategory == cat ? cat.color : AppTheme.cardDark, in: Capsule())
                            }
                            .buttonStyle(ScaleButtonStyle())
                        }
                    }
                    .padding(.horizontal, 22)
                }
            }

            // Date
            VStack(spacing: 8) {
                Text(loc("common.date")).font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22)
                DatePicker("", selection: $editDate, displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.compact).labelsHidden().tint(AppTheme.accent)
                    .padding(.horizontal, 22).frame(maxWidth: .infinity, alignment: .leading)
            }

            SheetField(label: "Notes (optional)", placeholder: "Add a note...", text: $editNotes)
                .padding(.horizontal, 22)

            Spacer(minLength: 40)
        }
    }

    private func loadEditState() {
        editName     = tx.name
        editAmount   = String(abs(tx.amount))
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
            Text(label).font(.system(size: 14)).foregroundStyle(AppTheme.textSecondary)
            Spacer()
            Text(value).font(.system(size: 14, weight: .medium)).foregroundStyle(AppTheme.textPrimary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }
}

// MARK: - Add Transaction Sheet (updated with IDR/USD)

struct AddTransactionSheet: View {
    let vm: AppViewModel
    var preselectedCategory: TxCategory? = nil
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var activeDebts: [DebtRecord]
    @Query(sort: \SalarySchedule.createdAt) private var salarySchedules: [SalarySchedule]

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
    @State private var appeared = false
    @State private var saveInPreferred = false
    @State private var showBudgetAlert = false
    @State private var pendingBudgetAlert: BudgetAlert? = nil
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
        let scheduled = salarySchedules.filter { $0.isActive }.reduce(0) { $0 + $1.amount }
        let cal = Calendar.current
        let monthStart = cal.safeDate(from: cal.dateComponents([.year, .month], from: Date()))
        // Add any extra income recorded this month (bonus, freelance, etc.) — exclude salary
        // to avoid double-counting since salary schedules already cover that
        let extraIncome = allCardTransactions
            .filter { $0.amount > 0 && $0.date >= monthStart && $0.category != .salary }
            .reduce(0) { $0 + $1.amount }
        return scheduled + extraIncome
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
        case .expense: return [.shopping, .food, .travel, .bills, .transport, .health, .investment, .other]
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

        var color: Color { self == .expense ? AppTheme.red : AppTheme.accent }
        var icon: String { self == .expense ? "arrow.up.circle.fill" : "arrow.down.circle.fill" }
    }

    var amount: Double { Double(amountText) ?? 0 }
    var isValid: Bool  { !name.trimmingCharacters(in: .whitespaces).isEmpty && amount > 0 }

    @ViewBuilder
    var currencyButtonLabel: some View {
        HStack(spacing: 6) {
            Text(CurrencyManager.symbol(for: currency))
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(AppTheme.accent)
            Text(currency)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AppTheme.textSecondary)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 10))
                .foregroundStyle(AppTheme.textSecondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 14)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppTheme.accent.opacity(0.3), lineWidth: 1))
    }

    var convertedPreview: String {
        guard amount > 0, currency != CurrencyManager.shared.preferredCurrency else { return "" }
        let pref = CurrencyManager.shared.preferredCurrency
        let conv = CurrencyManager.shared.convert(amount, from: currency, to: pref)
        return String(format: loc("tx.converted_in"),
                      CurrencyManager.shared.formatted(conv, currency: pref), pref)
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
                    VStack(spacing: 22) {

                        // Scan Receipt entry — opens the redesigned 3-screen scan
                        // flow inline. Only meaningful for expenses (you can't
                        // scan a salary), and only when the user has at least
                        // one card to save the resulting tx to.
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
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill(AppTheme.accent.opacity(0.15))
                                            .frame(width: 44, height: 44)
                                        Image(systemName: "doc.text.viewfinder")
                                            .font(.system(size: 20, weight: .semibold))
                                            .foregroundStyle(AppTheme.accent)
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(loc("receipt.entry.title"))
                                                .font(.system(size: 15, weight: .bold))
                                                .foregroundStyle(AppTheme.textPrimary)
                                            if !PremiumManager.shared.canAccess(.scanReceipt) {
                                                Image(systemName: "crown.fill")
                                                    .font(.system(size: 9, weight: .bold))
                                                    .foregroundStyle(.white)
                                                    .padding(3)
                                                    .background(Color(hex: "#F59E0B"), in: Circle())
                                            }
                                        }
                                        Text(loc("receipt.entry.subtitle"))
                                            .font(.system(size: 12))
                                            .foregroundStyle(AppTheme.textSecondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(AppTheme.textSecondary)
                                }
                                .padding(14)
                                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14)
                                        .stroke(AppTheme.accent.opacity(0.25), lineWidth: 1)
                                )
                            }
                            .buttonStyle(ScaleButtonStyle())
                            .padding(.horizontal, 22)
                            .padding(.top, 8)
                            .opacity(appeared ? 1 : 0)
                            .offset(y: appeared ? 0 : 20)
                            .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.04), value: appeared)
                        }

                        // Type
                        HStack(spacing: 0) {
                            ForEach(AddTxType.allCases, id: \.self) { type in
                                Button {
                                    HapticManager.shared.select()
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { txType = type }
                                    // Reset category if current one not valid for new type
                                    if !availableCategories.contains(selectedCategory) {
                                        selectedCategory = type == .expense ? .shopping : .salary
                                    }
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: type.icon).font(.system(size: 15))
                                        Text(type.title).font(.system(size: 15, weight: .semibold))
                                    }
                                    .foregroundStyle(txType == type ? AppTheme.bg : AppTheme.textSecondary)
                                    .frame(maxWidth: .infinity).padding(.vertical, 13)
                                    .background { if txType == type { Capsule().fill(type.color).shadow(color: type.color.opacity(0.4), radius: 8, y: 4) } }
                                }
                                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: txType)
                            }
                        }
                        .padding(4).background(AppTheme.cardDark, in: Capsule()).padding(.horizontal, 22).padding(.top, 8)
                        .opacity(appeared ? 1 : 0).offset(y: appeared ? 0 : 20)

                        // Amount + currency toggle
                        VStack(spacing: 8) {
                            Text(loc("common.amount")).font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22)
                            HStack(spacing: 10) {
                                Group {
                                    if PremiumManager.shared.canAccess(.smartConversion) {
                                        // Premium: full currency menu
                                        Menu {
                                            ForEach(CurrencyManager.supportedCurrencies, id: \.code) { c in
                                                Button {
                                                    HapticManager.shared.tap()
                                                    currency = c.code
                                                    // .onChange(of: currency) menangani auto-enable/disable
                                                    // saveInPreferred berdasarkan selectedCardCurrency
                                                } label: {
                                                    Label("\(c.flag) \(c.code) — \(c.name)", systemImage: currency == c.code ? "checkmark" : "")
                                                }
                                            }
                                        } label: {
                                            currencyButtonLabel
                                        }
                                    } else {
                                        // Free: locked — tapping shows paywall
                                        Button { HapticManager.shared.tap(); showConversionPaywall = true } label: {
                                            currencyButtonLabel
                                                .overlay(alignment: .topTrailing) {
                                                    Image(systemName: "lock.fill")
                                                        .font(.system(size: 8, weight: .bold))
                                                        .foregroundStyle(.white)
                                                        .padding(3)
                                                        // Padlock badge uses Royal's purple now —
                                                        // Premium tier (and its amber color) was
                                                        // removed. Consistent with other paid-gate
                                                        // affordances across the app.
                                                        .background(PremiumPlan.royal.color, in: Circle())
                                                        .offset(x: 4, y: -4)
                                                }
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }

                                TextField("0.00", text: $amountText)
                                    .font(.system(size: 32, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                                    .keyboardType(.decimalPad).padding(.horizontal, 16).padding(.vertical, 12)
                                    .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14)).frame(maxWidth: .infinity)
                            }
                            .padding(.horizontal, 22)

                            if !convertedPreview.isEmpty {
                                Text(convertedPreview).font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22)
                            } else if let p = AmountInputHelper.preview(amountText, currency: currency) {
                                // Show formatted preview ("Rp 5.000.000") under
                                // the raw input ("5000000") so users catch
                                // digit-count typos before saving. Only when
                                // there's no smart-conversion preview already
                                // — keeps the UI from getting noisy.
                                Text(p)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(AppTheme.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 22)
                            }
                            Text(CurrencyManager.shared.rateLabel).font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary.opacity(0.6))
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22)

                            // ── Smart auto-convert card ──────────────────────────
                            if amount > 0 && isForeignCurrency {
                                VStack(spacing: 10) {
                                    HStack(spacing: 10) {
                                        ZStack {
                                            Circle()
                                                .fill(AppTheme.accent.opacity(0.12))
                                                .frame(width: 36, height: 36)
                                            Image(systemName: "arrow.triangle.2.circlepath")
                                                .font(.system(size: 15, weight: .semibold))
                                                .foregroundStyle(AppTheme.accent)
                                        }
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(loc("tx.smart_convert"))
                                                .font(.system(size: 13, weight: .semibold))
                                                .foregroundStyle(AppTheme.textPrimary)
                                            Text(String(format: loc("tx.save_in_currency"), selectedCardCurrency))
                                                .font(.system(size: 11))
                                                .foregroundStyle(AppTheme.textSecondary)
                                        }
                                        Spacer()
                                        if isForeignCurrency {
                                            // Toggle dikunci ON — wajib konversi ketika
                                            // mata uang transaksi ≠ mata uang kartu.
                                            // User tidak bisa mematikannya.
                                            Text(loc("tx.required"))
                                                .font(.system(size: 10, weight: .semibold))
                                                .foregroundStyle(AppTheme.accent)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(AppTheme.accent.opacity(0.12), in: Capsule())
                                        } else {
                                            Toggle("", isOn: $saveInPreferred)
                                                .tint(AppTheme.accent)
                                                .labelsHidden()
                                                .onChange(of: saveInPreferred) { _, _ in HapticManager.shared.tap() }
                                        }
                                    }

                                    if saveInPreferred {
                                        Divider().background(AppTheme.cardMid)
                                        HStack {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(loc("tx.you_entered"))
                                                    .font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
                                                Text(CurrencyManager.shared.formatted(amount, currency: currency))
                                                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(AppTheme.textSecondary)
                                            }
                                            Image(systemName: "arrow.right")
                                                .font(.system(size: 12)).foregroundStyle(AppTheme.accent)
                                                .padding(.horizontal, 8)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(loc("tx.saved_as"))
                                                    .font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
                                                Text(CurrencyManager.shared.formatted(convertedAmount, currency: selectedCardCurrency))
                                                    .font(.system(size: 14, weight: .bold)).foregroundStyle(AppTheme.accent)
                                            }
                                            Spacer()
                                        }
                                        Text(CurrencyManager.shared.rateLabel)
                                            .font(.system(size: 10)).foregroundStyle(AppTheme.textSecondary.opacity(0.6))
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                                .padding(14)
                                .background(AppTheme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                                .overlay(RoundedRectangle(cornerRadius: 14).stroke(AppTheme.accent.opacity(saveInPreferred ? 0.4 : 0.15), lineWidth: 1))
                                .padding(.horizontal, 22)
                                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: saveInPreferred)
                                .animation(.spring(response: 0.35), value: amount)
                            }
                        }
                        .opacity(appeared ? 1 : 0).offset(y: appeared ? 0 : 20)
                        .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.06), value: appeared)

                        SheetField(label: loc("tx.name_label"),
                                   placeholder: selectedCategory == .debtPayment
                                       ? loc("tx.debt_placeholder")
                                       : loc("tx.name_placeholder"),
                                   text: $name)
                            .opacity(appeared ? 1 : 0).offset(y: appeared ? 0 : 20)
                            .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.1), value: appeared)
                            .onChange(of: name) { _, newName in
                                // Auto-categorize by merchant name
                                if txType == .expense,
                                   let suggested = SmartBudgetManager.suggestCategory(for: newName, txType: "Expense"),
                                   availableCategories.contains(suggested) {
                                    withAnimation(.spring(response: 0.3)) { selectedCategory = suggested }
                                }
                            }

                        // Auto-categorize hint
                        if txType == .expense,
                           let suggested = SmartBudgetManager.suggestCategory(for: name, txType: "Expense"),
                           suggested != selectedCategory {
                            HStack(spacing: 8) {
                                Image(systemName: suggested.icon).font(.system(size: 12)).foregroundStyle(suggested.color)
                                Text(String(format: loc("tx.auto_detected"), suggested.displayLabel))
                                    .font(.system(size: 12, weight: .medium)).foregroundStyle(AppTheme.textSecondary)
                                Spacer()
                                Button {
                                    HapticManager.shared.tap()
                                    withAnimation { selectedCategory = suggested }
                                } label: {
                                    Text(loc("tx.apply")).font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(AppTheme.bg)
                                        .padding(.horizontal, 10).padding(.vertical, 4)
                                        .background(suggested.color, in: Capsule())
                                }
                            }
                            .padding(.horizontal, 22)
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }

                        // Category
                        VStack(spacing: 8) {
                            Text(loc("common.category")).font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 10) {
                                    ForEach(availableCategories, id: \.self) { cat in
                                        Button {
                                            HapticManager.shared.tap()
                                            withAnimation(.spring(response: 0.3)) { selectedCategory = cat }
                                        } label: {
                                            HStack(spacing: 6) {
                                                Image(systemName: cat.icon).font(.system(size: 13))
                                                Text(cat.displayLabel).font(.system(size: 13, weight: .medium))
                                            }
                                            .foregroundStyle(selectedCategory == cat ? AppTheme.bg : AppTheme.textSecondary)
                                            .padding(.horizontal, 16).padding(.vertical, 10)
                                            .background(selectedCategory == cat ? cat.color : AppTheme.cardDark, in: Capsule())
                                        }
                                        .buttonStyle(ScaleButtonStyle())
                                    }
                                }
                                .padding(.horizontal, 22)
                            }
                        }
                        .opacity(appeared ? 1 : 0)
                        .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.14), value: appeared)

                        if vm.cards.count > 1 {
                            VStack(spacing: 8) {
                                Text(loc("debt.card")).font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22)
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 10) {
                                        ForEach(Array(vm.cards.enumerated()), id: \.element.id) { i, card in
                                            let cardCur = card.currency.isEmpty ? CurrencyManager.shared.preferredCurrency : card.currency
                                            Button {
                                                HapticManager.shared.tap(); selectedCardIndex = i
                                            } label: {
                                                VStack(alignment: .leading, spacing: 4) {
                                                    Text(card.holderName).font(.system(size: 12, weight: .semibold))
                                                    if card.isDigitalWallet {
                                                        Text(card.walletProvider.isEmpty ? loc("common.wallet") : card.walletProvider)
                                                            .font(.system(size: 11))
                                                            .foregroundStyle(selectedCardIndex == i ? AppTheme.bg.opacity(0.7) : AppTheme.textSecondary)
                                                    } else {
                                                        Text(".... \(card.cardNumber.suffix(4))")
                                                            .font(.system(size: 11))
                                                            .foregroundStyle(selectedCardIndex == i ? AppTheme.bg.opacity(0.7) : AppTheme.textSecondary)
                                                    }
                                                    Text(cardCur)
                                                        .font(.system(size: 10, weight: .bold))
                                                        .foregroundStyle(selectedCardIndex == i ? AppTheme.bg.opacity(0.6) : AppTheme.accent)
                                                }
                                                .foregroundStyle(selectedCardIndex == i ? AppTheme.bg : AppTheme.textPrimary)
                                                .padding(.horizontal, 16).padding(.vertical, 10)
                                                .background(selectedCardIndex == i ? AppTheme.accent : AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 12))
                                            }
                                            .buttonStyle(ScaleButtonStyle())
                                        }
                                    }
                                    .padding(.horizontal, 22)
                                }
                            }
                            .opacity(appeared ? 1 : 0)
                            .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.18), value: appeared)
                            .onChange(of: selectedCardIndex) { _, i in
                                guard i < vm.cards.count else { return }
                                let card = vm.cards[i]
                                let cardCur = card.currency.isEmpty
                                    ? CurrencyManager.shared.preferredCurrency
                                    : card.currency
                                currency = cardCur
                                saveInPreferred = false  // reset, kartu baru pasti sama currency-nya
                            }
                            // Bug 1 fix: auto-enable konversi saat user pilih mata uang
                            // berbeda dari kartu. Tanpa ini user bisa simpan transaksi USD
                            // ke kartu IDR tanpa konversi — balance jadi kacau.
                            .onChange(of: currency) { _, newCur in
                                withAnimation(.spring(response: 0.3)) {
                                    saveInPreferred = newCur != selectedCardCurrency
                                }
                            }
                        }

                        VStack(spacing: 8) {
                            Text(loc("common.date")).font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22)
                            DatePicker("", selection: $selectedDate, displayedComponents: [.date, .hourAndMinute])
                                .datePickerStyle(.compact).labelsHidden().tint(AppTheme.accent)
                                .padding(.horizontal, 22).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .opacity(appeared ? 1 : 0)
                        .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.2), value: appeared)

                        SheetField(label: loc("tx.notes"), placeholder: loc("tx.notes_placeholder"), text: $notes)
                            .padding(.horizontal, 22)
                            .opacity(appeared ? 1 : 0)
                            .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.22), value: appeared)

                        // No card warning — uses warning tone (orange) since
                        // the user can resolve this by adding a card; not
                        // an error state in itself.
                        if vm.cards.isEmpty {
                            InlineBanner(tone: .warning, message: loc("common.add_card_tx"))
                                .padding(.horizontal, 22)
                        }

                        // Negative balance — HARD BLOCK. Uses the standard
                        // error InlineBanner. The original two-line content
                        // (label + available-balance subtitle) is concatenated
                        // into one message — InlineBanner supports multi-line
                        // text via fixedSize(vertical:).
                        if wouldGoNegative && !vm.cards.isEmpty && txType == .expense {
                            let msg = loc("tx.insufficient") + "\n"
                                + String(format: loc("tx.available_balance"),
                                         CurrencyManager.shared.formatted(Swift.abs(selectedCardBalance),
                                                                          currency: selectedCardCurrency))
                            InlineBanner(tone: .error, message: msg)
                                .padding(.horizontal, 22)
                        }

                        if showError {
                            InlineBanner(tone: .error, message: loc("tx.valid_error"))
                                .padding(.horizontal, 22)
                        }

                        Button { saveTransaction() } label: {
                            // `canSubmit` precomputed once for both background
                            // and foreground styling — avoids the previous
                            // bug where the foreground was always
                            // `AppTheme.bg` (light text) over a 0.3-opacity
                            // gray background, producing near-invisible label
                            // when disabled.
                            let canSubmit = isValid && !(wouldGoNegative && txType == .expense)
                            HStack(spacing: 10) {
                                Image(systemName: txType.icon).font(.system(size: 16))
                                Text(String(format: loc("tx.add_type"), txType.title)).font(.system(size: 16, weight: .bold))
                            }
                            .foregroundStyle(canSubmit ? AppTheme.bg : AppTheme.textSecondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 16)
                            .background(canSubmit ? txType.color : AppTheme.textSecondary.opacity(0.3), in: Capsule())
                            .shadow(color: canSubmit ? txType.color.opacity(0.4) : .clear, radius: 12, y: 6)
                        }
                        .buttonStyle(ScaleButtonStyle()).disabled(!isValid || vm.cards.isEmpty || (wouldGoNegative && txType == .expense)).padding(.horizontal, 22).padding(.top, 6)
                        .opacity(appeared ? 1 : 0)
                        .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.26), value: appeared)

                        Spacer(minLength: 40)
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
            // Start on the card the user was viewing on home
            selectedCardIndex = min(vm.selectedCardIndex, max(vm.cards.count - 1, 0))
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
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.15)) { appeared = true }
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
        .confirmationDialog(
            pendingBudgetAlert?.isExceeded == true
                ? loc("tx.budget_exceed")
                : loc("tx.approach_limit"),
            isPresented: $showBudgetAlert,
            titleVisibility: .visible
        ) {
            Button(loc("tx.add_anyway"), role: .destructive) { commitTransaction() }
            Button(loc("common.cancel"), role: .cancel) { pendingBudgetAlert = nil }
        } message: {
            if let alert = pendingBudgetAlert {
                if alert.isExceeded {
                    Text(String(format: loc("tx.budget_over_msg"),
                                alert.displayLabel.lowercased(),
                                CurrencyManager.shared.formatted(alert.over, currency: CurrencyManager.shared.preferredCurrency),
                                CurrencyManager.shared.formatted(alert.limit, currency: CurrencyManager.shared.preferredCurrency)))
                } else {
                    Text(String(format: loc("tx.budget_approach_msg"),
                                alert.displayLabel.lowercased(),
                                CurrencyManager.shared.formatted(alert.limit, currency: CurrencyManager.shared.preferredCurrency),
                                CurrencyManager.shared.formatted(alert.limit - alert.spent, currency: CurrencyManager.shared.preferredCurrency)))
                }
            }
        }
    }

    private func saveTransaction() {
        guard isValid else { HapticManager.shared.error(); withAnimation { showError = true }; return }
        guard !vm.cards.isEmpty else {
            HapticManager.shared.error(); withAnimation { showError = true }; return
        }

        // Smart budget check — only for expenses
        if txType == .expense {
            if let alert = SmartBudgetManager.shared.wouldExceed(
                category: selectedCategory,
                amount: effectiveAmount,
                transactions: allCardTransactions,
                income: monthlyIncome
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
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(loc("tx.max_range"))
                        .font(.system(size: 12))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.top, 16)

            VStack(spacing: 16) {
                VStack(spacing: 6) {
                    Text(loc("tx.start_date"))
                        .font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
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
                        .font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
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
                    Image(systemName: "calendar.badge.clock").font(.system(size: 13)).foregroundStyle(AppTheme.accent)
                    Text(days == 1 ? String(format: loc("search.day_results"), days) : String(format: loc("search.days_results"), days))
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(AppTheme.textSecondary)
                    Spacer()
                }
                .padding(12)
                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 12))
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
                    .font(.system(size: 16, weight: .bold)).foregroundStyle(AppTheme.bg)
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                    .background(AppTheme.accent, in: Capsule())
                    .shadow(color: AppTheme.accent.opacity(0.35), radius: 12, y: 6)
            }
            .buttonStyle(ScaleButtonStyle())
            .padding(.horizontal, 22).padding(.bottom, 32)
        }
        .onAppear { localStart = startDate; localEnd = endDate }
    }
}
