import SwiftUI
import SwiftData

// MARK: - Search
 Date Period

enum SearchPeriod: String, CaseIterable {
    case all       = "All time"
    case today     = "Today"
    case yesterday = "Yesterday"
    case thisWeek  = "This week"
    case lastMonth = "Last month"
    case last3     = "Last 3 months"
    case thisYear  = "This year"

    func range() -> (start: Date, end: Date)? {
        let cal = Calendar.current
        let now = Date()
        switch self {
        case .all:       return nil
        case .today:     return (cal.startOfDay(for: now), now)
        case .yesterday:
            let yStart = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now))!
            return (yStart, cal.startOfDay(for: now))
        case .thisWeek:
            return (cal.date(byAdding: .day, value: -7, to: now)!, now)
        case .lastMonth:
            return (cal.date(byAdding: .month, value: -1, to: now)!, now)
        case .last3:
            return (cal.date(byAdding: .month, value: -3, to: now)!, now)
        case .thisYear:
            let start = cal.date(from: cal.dateComponents([.year], from: now))!
            return (start, now)
        }
    }
}

// MARK: - Search View

struct SearchView: View {
    let vm: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selectedFilter: TxCategory? = nil
    @State private var selectedPeriod: SearchPeriod = .all
    @State private var appeared = false
    @FocusState private var focused: Bool
    @State private var selectedTx: TxRecord? = nil

    var allTransactions: [TxRecord] { vm.recentTransactions }

    var periodFiltered: [TxRecord] {
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
        return dict.keys.sorted(by: >).map { day in
            let label: String
            if cal.isDateInToday(day)          { label = "Today" }
            else if cal.isDateInYesterday(day) { label = "Yesterday" }
            else {
                let weekAgo = cal.date(byAdding: .day, value: -7, to: Date())!
                if day >= weekAgo {
                    label = day.formatted(.dateTime.weekday(.wide))
                } else {
                    label = day.formatted(.dateTime.day().month(.wide).year())
                }
            }
            return (label: label, date: day, txs: dict[day]!.sorted { $0.date > $1.date })
        }
    }

    var availableCategories: [TxCategory] {
        let used = Set(periodFiltered.map { $0.category })
        return TxCategory.allCases.filter { used.contains($0) }
    }

    var totalAmount: Double { filtered.reduce(0) { $0 + $1.amount } }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Search bar
                    HStack(spacing: 12) {
                        HStack(spacing: 10) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 16))
                                .foregroundStyle(AppTheme.textSecondary)
                            TextField("Search transactions...", text: $query)
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

                        Button("Cancel") { HapticManager.shared.tap(); dismiss() }
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
                                } label: {
                                    HStack(spacing: 5) {
                                        if period != .all {
                                            Image(systemName: "calendar")
                                                .font(.system(size: 10, weight: .medium))
                                        }
                                        Text(period.rawValue)
                                            .font(.system(size: 12, weight: selectedPeriod == period ? .semibold : .regular))
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
                                FilterPill(label: "All categories", isSelected: selectedFilter == nil) {
                                    HapticManager.shared.tap()
                                    withAnimation(.spring(response: 0.3)) { selectedFilter = nil }
                                }
                                ForEach(availableCategories, id: \.self) { cat in
                                    FilterPill(label: cat.rawValue, isSelected: selectedFilter == cat, color: cat.color) {
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
                            Text(query.isEmpty ? "No transactions in this period" : "No results for \"\(query)\"")
                                .font(.system(size: 15)).foregroundStyle(AppTheme.textSecondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.top, 80)
                    } else {
                        ScrollView(showsIndicators: false) {
                            VStack(spacing: 0) {
                                // Summary bar
                                HStack {
                                    Text("\(filtered.count) transaction\(filtered.count == 1 ? "" : "s")")
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
            .navigationBarHidden(true)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { focused = true }
        }
        .sheet(item: $selectedTx) { tx in
            TransactionDetailSheet(tx: tx)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
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
        if cal.isDateInToday(tx.date)     { return "Today, \(tx.date.formatted(date: .omitted, time: .shortened))" }
        if cal.isDateInYesterday(tx.date) { return "Yesterday, \(tx.date.formatted(date: .omitted, time: .shortened))" }
        return tx.date.formatted(date: .abbreviated, time: .shortened)
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
                    Text(tx.category.rawValue)
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
                    Text("Income").font(.system(size: 10)).foregroundStyle(AppTheme.textSecondary)
                } else {
                    Text(tx.type).font(.system(size: 10)).foregroundStyle(AppTheme.textSecondary)
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

    enum EditType: String, CaseIterable {
        case expense = "Expense"
        case income  = "Income"
        var color: Color { self == .expense ? AppTheme.red : AppTheme.accent }
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
            .navigationTitle(isEditing ? "Edit Transaction" : "Transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isEditing ? "Cancel" : "Close") {
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
                        Button("Save") { saveEdits() }
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
        .confirmationDialog("Delete transaction?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                context.delete(tx)
                try? context.save()
                HapticManager.shared.warning()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
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

                Text(tx.amount >= 0 ? "+\(formattedAmount)" : "-\(formattedAmount)")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(tx.amount >= 0 ? AppTheme.green : AppTheme.red)

                Text(convertedLabel)
                    .font(.system(size: 14))
                    .foregroundStyle(AppTheme.textSecondary)

                if CurrencyManager.shared.isLoading {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.7).tint(AppTheme.textSecondary)
                        Text("Updating rate...").font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
                    }
                } else if let updated = CurrencyManager.shared.lastUpdated {
                    Text("Rate: \(CurrencyManager.shared.rateLabel) as of \(updated.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }
            .padding(.top, 16)

            // Details card
            VStack(spacing: 0) {
                DetailRow(label: "Name", value: tx.name)
                Divider().background(AppTheme.cardMid).padding(.horizontal, 18)
                DetailRow(label: "Date", value: tx.date.formatted(date: .complete, time: .shortened))
                Divider().background(AppTheme.cardMid).padding(.horizontal, 18)
                DetailRow(label: "Category", value: tx.category.rawValue)
                Divider().background(AppTheme.cardMid).padding(.horizontal, 18)
                DetailRow(label: "Type", value: tx.type)
                Divider().background(AppTheme.cardMid).padding(.horizontal, 18)
                DetailRow(label: "Currency", value: tx.currency)
                if !tx.notes.isEmpty {
                    Divider().background(AppTheme.cardMid).padding(.horizontal, 18)
                    DetailRow(label: "Notes", value: tx.notes)
                }
            }
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 18))
            .padding(.horizontal, 22)

            // Delete button
            Button {
                HapticManager.shared.warning()
                showDeleteConfirm = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "trash").font(.system(size: 16))
                    Text("Delete Transaction").font(.system(size: 15, weight: .semibold))
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
                        Text(type.rawValue)
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
                Text("Amount").font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
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
                Text("Category").font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
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
                Text("Date").font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22)
                DatePicker("", selection: $editDate, displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.compact).labelsHidden().tint(AppTheme.accent)
                    .padding(.horizontal, 22).frame(maxWidth: .infinity, alignment: .leading)
            }

            SheetField(label: "Notes (optional)", placeholder: "Add a note...", text: $editNotes)

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
        tx.type      = editType == .expense ? "Purchase" : "Income"
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

// MARK: - Notification Center

struct NotificationCenterView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \SalarySchedule.createdAt) private var schedules: [SalarySchedule]
    @Environment(\.modelContext) private var context

    var notifications: [AppNotification] {
        var result: [AppNotification] = []
        for s in schedules where s.isActive {
            let days = SalaryDateEngine.daysUntilPay(dayOfMonth: s.dayOfMonth)
            let date = SalaryDateEngine.nextPayDate(dayOfMonth: s.dayOfMonth)
            let adjusted = SalaryDateEngine.wasAdjusted(intended: s.dayOfMonth, actual: date)
            if days == 0 {
                result.append(AppNotification(
                    icon: "banknote.fill", iconColor: AppTheme.accent,
                    title: "Payday today!",
                    body: "\(s.label) - \(CurrencyManager.shared.formatted(s.amount, currency: s.currency)) should arrive today.",
                    time: "Today", isUrgent: true))
            } else if days == 1 {
                result.append(AppNotification(
                    icon: "clock.fill", iconColor: AppTheme.orange,
                    title: "Payday tomorrow",
                    body: "\(s.label) arrives tomorrow\(adjusted ? " (date adjusted from weekend)" : "").",
                    time: "Tomorrow", isUrgent: true))
            } else if days <= 7 {
                result.append(AppNotification(
                    icon: "calendar.badge.clock", iconColor: AppTheme.blue,
                    title: "Payday in \(days) days",
                    body: "\(s.label) - \(date.formatted(.dateTime.weekday(.wide).day().month(.wide)))\(adjusted ? " (adjusted)" : "").",
                    time: "In \(days) days", isUrgent: false))
            }
        }
        if result.isEmpty {
            result.append(AppNotification(
                icon: "checkmark.circle.fill", iconColor: AppTheme.accent,
                title: "All caught up!",
                body: "No upcoming paydays in the next 7 days.",
                time: "Now", isUrgent: false))
        }
        return result
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 12) {
                        ForEach(Array(notifications.enumerated()), id: \.offset) { _, notif in
                            NotificationRow(notif: notif)
                                .padding(.horizontal, 22)
                        }
                        Spacer(minLength: 40)
                    }
                    .padding(.top, 8)
                }
            }
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }
        }
    }
}

struct AppNotification {
    let icon: String
    let iconColor: Color
    let title: String
    let body: String
    let time: String
    let isUrgent: Bool
}

struct NotificationRow: View {
    let notif: AppNotification
    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(notif.iconColor.opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: notif.icon)
                    .font(.system(size: 20))
                    .foregroundStyle(notif.iconColor)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(notif.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Spacer()
                    Text(notif.time)
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                Text(notif.body)
                    .font(.system(size: 13))
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineSpacing(2)
            }
        }
        .padding(14)
        .background(notif.isUrgent ? notif.iconColor.opacity(0.06) : AppTheme.cardDark,
                    in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .stroke(notif.isUrgent ? notif.iconColor.opacity(0.2) : Color.clear, lineWidth: 1))
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

    private var monthlyIncome: Double {
        salarySchedules.filter { $0.isActive }.reduce(0) { $0 + $1.amount }
    }

    private var allCardTransactions: [TxRecord] {
        vm.cards.flatMap { $0.transactions }
    }

    private var preferredCurrency: String { CurrencyManager.shared.preferredCurrency }
    private var isForeignCurrency: Bool { currency != preferredCurrency }

    private var convertedAmount: Double {
        CurrencyManager.shared.convert(amount, from: currency, to: preferredCurrency)
    }

    private var effectiveCurrency: String { saveInPreferred ? preferredCurrency : currency }
    private var effectiveAmount: Double   { saveInPreferred ? convertedAmount : amount }

    // Expense and income categories are now separate
    private var availableCategories: [TxCategory] {
        switch txType {
        case .expense: return [.shopping, .food, .travel, .bills, .transport, .health, .other]
        case .income:  return [.salary, .freelance, .business, .investment, .bonus, .gift, .incomeOther]
        }
    }

    enum AddTxType: String, CaseIterable {
        case expense = "Expense"
        case income  = "Income"
        var color: Color { self == .expense ? AppTheme.red : AppTheme.accent }
        var icon: String { self == .expense ? "arrow.up.circle.fill" : "arrow.down.circle.fill" }
    }

    var amount: Double { Double(amountText) ?? 0 }
    var isValid: Bool  { !name.trimmingCharacters(in: .whitespaces).isEmpty && amount > 0 }

    var convertedPreview: String {
        guard amount > 0, currency != CurrencyManager.shared.preferredCurrency else { return "" }
        let pref = CurrencyManager.shared.preferredCurrency
        let conv = CurrencyManager.shared.convert(amount, from: currency, to: pref)
        return "≈ \(CurrencyManager.shared.formatted(conv, currency: pref)) in \(pref)"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 22) {

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
                                        Text(type.rawValue).font(.system(size: 15, weight: .semibold))
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
                            Text("Amount").font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22)
                            HStack(spacing: 10) {
                                Menu {
                                    ForEach(CurrencyManager.supportedCurrencies, id: \.code) { c in
                                        Button {
                                            HapticManager.shared.tap()
                                            currency = c.code
                                            if c.code == preferredCurrency { saveInPreferred = false }
                                        } label: {
                                            Label("\(c.flag) \(c.code) — \(c.name)", systemImage: currency == c.code ? "checkmark" : "")
                                        }
                                    }
                                } label: {
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

                                TextField("0.00", text: $amountText)
                                    .font(.system(size: 32, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                                    .keyboardType(.decimalPad).padding(.horizontal, 16).padding(.vertical, 12)
                                    .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14)).frame(maxWidth: .infinity)
                            }
                            .padding(.horizontal, 22)

                            if !convertedPreview.isEmpty {
                                Text(convertedPreview).font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22)
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
                                            Text("Smart Conversion")
                                                .font(.system(size: 13, weight: .semibold))
                                                .foregroundStyle(AppTheme.textPrimary)
                                            Text("Save in \(preferredCurrency) using live rate")
                                                .font(.system(size: 11))
                                                .foregroundStyle(AppTheme.textSecondary)
                                        }
                                        Spacer()
                                        Toggle("", isOn: $saveInPreferred)
                                            .tint(AppTheme.accent)
                                            .labelsHidden()
                                            .onChange(of: saveInPreferred) { _, _ in HapticManager.shared.tap() }
                                    }

                                    if saveInPreferred {
                                        Divider().background(AppTheme.cardMid)
                                        HStack {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text("You entered")
                                                    .font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
                                                Text(CurrencyManager.shared.formatted(amount, currency: currency))
                                                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(AppTheme.textSecondary)
                                            }
                                            Image(systemName: "arrow.right")
                                                .font(.system(size: 12)).foregroundStyle(AppTheme.accent)
                                                .padding(.horizontal, 8)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text("Saved as")
                                                    .font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
                                                Text(CurrencyManager.shared.formatted(convertedAmount, currency: preferredCurrency))
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

                        SheetField(label: "Name / Description",
                                   placeholder: selectedCategory == .debtPayment ? "e.g. BCA Credit Card Payment" : "e.g. Spotify, Salary...",
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
                                Text("Auto-detected: \(suggested.rawValue)")
                                    .font(.system(size: 12, weight: .medium)).foregroundStyle(AppTheme.textSecondary)
                                Spacer()
                                Button {
                                    HapticManager.shared.tap()
                                    withAnimation { selectedCategory = suggested }
                                } label: {
                                    Text("Apply").font(.system(size: 11, weight: .semibold))
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
                            Text("Category").font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
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
                                                Text(cat.rawValue).font(.system(size: 13, weight: .medium))
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
                                Text("Card").font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22)
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 10) {
                                        ForEach(Array(vm.cards.enumerated()), id: \.element.id) { i, card in
                                            Button {
                                                HapticManager.shared.tap(); selectedCardIndex = i
                                            } label: {
                                                VStack(alignment: .leading, spacing: 4) {
                                                    Text(card.holderName).font(.system(size: 12, weight: .semibold))
                                                    Text(".... \(card.cardNumber.suffix(4))").font(.system(size: 11))
                                                        .foregroundStyle(selectedCardIndex == i ? AppTheme.bg.opacity(0.7) : AppTheme.textSecondary)
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
                        }

                        VStack(spacing: 8) {
                            Text("Date").font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22)
                            DatePicker("", selection: $selectedDate, displayedComponents: [.date, .hourAndMinute])
                                .datePickerStyle(.compact).labelsHidden().tint(AppTheme.accent)
                                .padding(.horizontal, 22).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .opacity(appeared ? 1 : 0)
                        .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.2), value: appeared)

                        SheetField(label: "Notes (optional)", placeholder: "Add a note...", text: $notes)
                            .opacity(appeared ? 1 : 0)
                            .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.22), value: appeared)

                        // No card warning
                        if vm.cards.isEmpty {
                            HStack(spacing: 10) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 14)).foregroundStyle(AppTheme.orange)
                                Text("Add a card first before recording transactions")
                                    .font(.system(size: 13)).foregroundStyle(AppTheme.orange)
                            }
                            .padding(.horizontal, 22).transition(.opacity)
                        }

                        // Negative balance — HARD BLOCK
                        if wouldGoNegative && !vm.cards.isEmpty && txType == .expense {
                            HStack(spacing: 10) {
                                Image(systemName: "exclamationmark.octagon.fill")
                                    .font(.system(size: 14)).foregroundStyle(AppTheme.red)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Insufficient balance — cannot add expense")
                                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(AppTheme.red)
                                    Text("Available: \(CurrencyManager.shared.formatted(Swift.abs(selectedCardBalance), currency: currency))")
                                        .font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
                                }
                            }
                            .padding(12)
                            .background(AppTheme.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppTheme.red.opacity(0.35), lineWidth: 1.5))
                            .padding(.horizontal, 22).transition(.opacity)
                        }

                        if showError {
                            Text("Please enter a name and a valid amount")
                                .font(.system(size: 13)).foregroundStyle(AppTheme.red).padding(.horizontal, 22).transition(.opacity)
                        }

                        Button { saveTransaction() } label: {
                            HStack(spacing: 10) {
                                Image(systemName: txType.icon).font(.system(size: 16))
                                Text("Add \(txType.rawValue)").font(.system(size: 16, weight: .bold))
                            }
                            .foregroundStyle(AppTheme.bg).frame(maxWidth: .infinity).padding(.vertical, 16)
                            .background(isValid ? txType.color : AppTheme.textSecondary.opacity(0.3), in: Capsule())
                            .shadow(color: isValid ? txType.color.opacity(0.4) : .clear, radius: 12, y: 6)
                        }
                        .buttonStyle(ScaleButtonStyle()).disabled(!isValid || vm.cards.isEmpty || (wouldGoNegative && txType == .expense)).padding(.horizontal, 22).padding(.top, 6)
                        .opacity(appeared ? 1 : 0)
                        .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.26), value: appeared)

                        Spacer(minLength: 40)
                    }
                }
            }
            .navigationTitle("New Transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { HapticManager.shared.tap(); dismiss() }.foregroundStyle(AppTheme.textSecondary)
                }

            }
        }
        .onAppear {
            CurrencyManager.shared.fetchRate()
            if let pre = preselectedCategory {
                selectedCategory = pre
                if pre == .debtPayment { txType = .expense }
            }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.15)) { appeared = true }
        }
        .confirmationDialog(
            pendingBudgetAlert?.isExceeded == true
                ? "⚠️ Budget Exceeded"
                : "💡 Approaching Limit",
            isPresented: $showBudgetAlert,
            titleVisibility: .visible
        ) {
            Button("Add anyway", role: .destructive) { commitTransaction() }
            Button("Cancel", role: .cancel) { pendingBudgetAlert = nil }
        } message: {
            if let alert = pendingBudgetAlert {
                if alert.isExceeded {
                    Text("This will put your \(alert.group.label.lowercased()) spending \(CurrencyManager.shared.formatted(alert.over, currency: CurrencyManager.shared.preferredCurrency)) over your monthly limit of \(CurrencyManager.shared.formatted(alert.limit, currency: CurrencyManager.shared.preferredCurrency)). Are you sure?")
                } else {
                    Text("You'll reach 90% of your \(alert.group.label.lowercased()) budget (\(CurrencyManager.shared.formatted(alert.limit, currency: CurrencyManager.shared.preferredCurrency))/month). You have \(CurrencyManager.shared.formatted(alert.limit - alert.spent, currency: CurrencyManager.shared.preferredCurrency)) left.")
                }
            }
        }
    }

    private var selectedCardBalance: Double {
        guard !vm.cards.isEmpty else { return 0 }
        let card = vm.cards[selectedCardIndex]
        return card.balance + card.transactions.reduce(0) { $0 + $1.amount }
    }

    private var wouldGoNegative: Bool {
        guard txType == .expense, effectiveAmount > 0 else { return false }
        return selectedCardBalance - effectiveAmount < 0
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
        let txType_str  = selectedCategory == .debtPayment ? "Debt Payment"
                        : txType == .expense ? "Purchase" : "Income"

        let record = TxRecord(
            name: name.trimmingCharacters(in: .whitespaces),
            date: selectedDate, amount: finalAmount,
            type: txType_str,
            icon: String(name.prefix(2).uppercased()),
            iconBgHex: selectedCategory.iconBg,
            category: selectedCategory, currency: effectiveCurrency, notes: notes
        )
        vm.cards[selectedCardIndex].transactions.append(record)

        // Auto-reduce linked debt balance
        if selectedCategory == .debtPayment,
           let debtID = selectedDebtID,
           let debt = activeDebts.first(where: { $0.id == debtID }) {
            debt.currentBalance = max(debt.currentBalance - abs(amount), 0)
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
