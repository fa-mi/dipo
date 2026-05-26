import SwiftUI
import SwiftData

// MARK: - SwiftData Model

@Model
final class SalarySchedule {
    var id: UUID
    var label: String
    var amount: Double
    var dayOfMonth: Int
    var currency: String
    var isActive: Bool
    var cardID: UUID?
    var createdAt: Date
    var lastCreditedMonth: Int
    var lastCreditedYear: Int
    var isPinned: Bool

    init(label: String, amount: Double, dayOfMonth: Int,
         currency: String = CurrencyManager.shared.preferredCurrency, cardID: UUID? = nil) {
        self.id = UUID()
        self.label = label
        self.amount = amount
        self.dayOfMonth = dayOfMonth
        self.currency = currency
        self.isActive = true
        self.cardID = cardID
        self.createdAt = .now
        self.lastCreditedMonth = 0
        self.lastCreditedYear = 0
        self.isPinned = false
    }
}

// MARK: - Salary Date Engine

struct SalaryDateEngine {

    // MARK: - Business Day Check
    // Uses IndonesianHolidayService which fetches from api-harilibur.vercel.app
    // and caches locally — works offline after first successful fetch.

    static func isPublicHoliday(_ date: Date, cal: Calendar) -> Bool {
        IndonesianHolidayService.shared.isHoliday(date)
    }

    static func actualPayDate(dayOfMonth: Int, month: Int, year: Int) -> Date {
        let cal = Calendar.current
        var components = DateComponents(year: year, month: month, day: dayOfMonth)
        // ✅ safe: use ?? 28 fallback so a bad locale/timezone never crashes
        let lastDay = cal.range(of: .day, in: .month,
                                for: cal.safeDate(from: components))?.count ?? 28
        components.day = min(dayOfMonth, lastDay)
        guard var date = cal.date(from: components) else { return .now }

        // Walk backward day-by-day until we land on a business day, but never
        // cross the month boundary. Edge case this guards: dayOfMonth = 1 in
        // a month where Jan 1 + 2 are weekend/holiday — naive backward walk
        // would land in December of the previous year, then the credit engine
        // would record a Jan tx with date = Dec, corrupting that month's
        // statistics. If we exhaust all backward business days within the
        // target month, we instead walk FORWARD from the original date until
        // we find one (still preferring "pay early" semantics overall, but
        // never mislabeling the month).
        let originalMonth = month
        var backwardSteps = 0
        while !isBusinessDay(date, cal: cal) {
            date = cal.safeDate(byAdding: .day, value: -1, to: date)
            backwardSteps += 1
            if cal.component(.month, from: date) != originalMonth {
                // Crossed the boundary — reset and try forward instead.
                guard let resetDate = cal.date(from: components) else { return .now }
                date = resetDate
                while !isBusinessDay(date, cal: cal) {
                    let next = cal.safeDate(byAdding: .day, value: 1, to: date)
                    if cal.component(.month, from: next) != originalMonth {
                        // Whole month is non-business (impossible in practice).
                        // Return the original component date as a last resort.
                        return resetDate
                    }
                    date = next
                }
                return date
            }
            // Defensive cap: shouldn't take more than ~7 steps in any sane
            // calendar.
            if backwardSteps > 31 { return date }
        }
        return date
    }

    static func isBusinessDay(_ date: Date, cal: Calendar) -> Bool {
        let weekday = cal.component(.weekday, from: date)
        guard weekday != 1 && weekday != 7 else { return false }   // Sunday=1, Saturday=7
        return !isPublicHoliday(date, cal: cal)
    }

    static func nextPayDate(dayOfMonth: Int) -> Date {
        let cal = Calendar.current
        let now = Date()
        let currentMonth = cal.component(.month, from: now)
        let currentYear  = cal.component(.year, from: now)
        let thisMonth = actualPayDate(dayOfMonth: dayOfMonth,
                                      month: currentMonth, year: currentYear)
        if thisMonth >= cal.startOfDay(for: now) {
            return thisMonth
        }
        let nextMonth = currentMonth == 12 ? 1 : currentMonth + 1
        let nextYear  = currentMonth == 12 ? currentYear + 1 : currentYear
        return actualPayDate(dayOfMonth: dayOfMonth, month: nextMonth, year: nextYear)
    }

    static func daysUntilPay(dayOfMonth: Int) -> Int {
        let cal   = Calendar.current
        let next  = nextPayDate(dayOfMonth: dayOfMonth)
        let today = cal.startOfDay(for: .now)
        return cal.dateComponents([.day], from: today, to: next).day ?? 0
    }

    static func upcomingDates(dayOfMonth: Int, count: Int = 6) -> [Date] {
        let cal = Calendar.current
        var results: [Date] = []
        let now = Date()
        var month = cal.component(.month, from: now)
        var year  = cal.component(.year, from: now)
        while results.count < count {
            let d = actualPayDate(dayOfMonth: dayOfMonth, month: month, year: year)
            if d >= cal.startOfDay(for: now) || results.isEmpty {
                results.append(d)
            }
            month += 1
            if month > 12 { month = 1; year += 1 }
        }
        return Array(results.prefix(count))
    }

    static func isToday(_ date: Date) -> Bool {
        Calendar.current.isDateInToday(date)
    }

    static func isTomorrow(_ date: Date) -> Bool {
        Calendar.current.isDateInTomorrow(date)
    }

    static func wasAdjusted(intended: Int, actual: Date) -> Bool {
        Calendar.current.component(.day, from: actual) != intended
    }
}

// MARK: - Salary ViewModel

@Observable
final class SalaryViewModel {
    var showAddSheet = false
    var editingSchedule: SalarySchedule? = nil
    var formLabel: String = ""
    var formAmount: String = ""
    var formDay: Int = 25
    var formCurrency: String = CurrencyManager.shared.preferredCurrency
    var formCardID: UUID? = nil
    var formError: String? = nil

    let currencies = ["USD", "IDR"]

    func resetForm() {
        formLabel    = ""
        formAmount   = ""
        formDay      = 25
        formCurrency = CurrencyManager.shared.preferredCurrency
        formCardID   = nil
        formError    = nil
        editingSchedule = nil
    }

    func loadForEdit(_ s: SalarySchedule, cards: [BankCard]) {
        formLabel  = s.label
        formAmount = String(s.amount)
        formDay    = s.dayOfMonth
        formCardID = s.cardID
        // Lock to card currency — corrects any old mismatched schedules on edit
        if let id = s.cardID, let card = cards.first(where: { $0.id == id }) {
            formCurrency = card.currency
        } else {
            formCurrency = s.currency
        }
        editingSchedule = s
        showAddSheet = true
    }

    func validate() -> Bool {
        guard !formLabel.trimmingCharacters(in: .whitespaces).isEmpty else {
            formError = loc("salary.error.label"); return false
        }
        guard let amt = Double(formAmount), amt > 0 else {
            formError = loc("salary.error.amount"); return false
        }
        guard formCardID != nil else {
            formError = loc("salary.error.card"); return false
        }
        formError = nil
        return true
    }
}

// MARK: - Salary Main View

struct SalaryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \SalarySchedule.createdAt) private var schedules: [SalarySchedule]
    @Query(sort: \BankCard.sortOrder) private var cards: [BankCard]
    @State private var vm = SalaryViewModel()
    @State private var appeared = false

    var body: some View {
        NavigationStack {
        ZStack {
            AppTheme.bg.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    SalaryNavBar(vm: vm)
                        .padding(.horizontal, 22)
                        .padding(.top, 20)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : -12)

                    if schedules.isEmpty {
                        SalaryEmptyState(vm: vm)
                            .padding(.top, 60)
                            .opacity(appeared ? 1 : 0)
                    } else {
                        VStack(spacing: 20) {
                            ForEach(Array(schedules.enumerated()), id: \.element.id) { i, schedule in
                                SalaryCard(schedule: schedule, allSchedules: schedules, cards: cards, vm: vm, context: context)
                                    .opacity(appeared ? 1 : 0)
                                    .offset(y: appeared ? 0 : 24)
                                    .animation(
                                        .spring(response: 0.55, dampingFraction: 0.8)
                                            .delay(Double(i) * 0.07),
                                        value: appeared
                                    )
                            }
                        }
                        .padding(.horizontal, 22)
                        .padding(.top, 24)
                    }
                    Spacer(minLength: 120)
                }
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.8)) { appeared = true }
        }
        .sheet(isPresented: $vm.showAddSheet, onDismiss: { vm.resetForm() }) {
            SalaryFormSheet(vm: vm, context: context)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
                .preferredColorScheme(appColorScheme())
        }
        } // end NavigationStack
    }
}

// MARK: - Nav Bar

struct SalaryNavBar: View {
    @Bindable var vm: SalaryViewModel
    @Query(sort: \BankCard.sortOrder) private var cards: [BankCard]
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(loc("salary.title"))
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(loc("salary.smart_sub"))
                    .font(.system(size: 13))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            Spacer()
            Button {
                HapticManager.shared.tap()
                vm.resetForm()
                vm.showAddSheet = true
            } label: {
                ZStack {
                    Circle()
                        .fill(cards.isEmpty ? AppTheme.cardMid : AppTheme.accent)
                        .frame(width: 42, height: 42)
                        .shadow(color: cards.isEmpty ? .clear : AppTheme.accent.opacity(0.4), radius: 10, y: 4)
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(cards.isEmpty ? AppTheme.textSecondary : AppTheme.bg)
                }
            }
            .disabled(cards.isEmpty)
            .buttonStyle(ScaleButtonStyle())
        }
    }
}

// MARK: - Empty State

struct SalaryEmptyState: View {
    @Bindable var vm: SalaryViewModel
    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(AppTheme.cardDark)
                    .frame(width: 88, height: 88)
                    .overlay(Circle().stroke(AppTheme.accent.opacity(0.2), lineWidth: 1))
                Image(systemName: "banknote")
                    .font(.system(size: 36))
                    .foregroundStyle(AppTheme.accent)
            }
            VStack(spacing: 8) {
                Text(loc("salary.no_salary"))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(loc("salary.nil"))
                    .font(.system(size: 14))
                    .foregroundStyle(AppTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }
            Button {
                HapticManager.shared.tap()
                vm.resetForm()
                vm.showAddSheet = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus").font(.system(size: 14, weight: .semibold))
                    Text(loc("salary.add")).font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(AppTheme.bg)
                .padding(.horizontal, 32)
                .padding(.vertical, 14)
                .background(AppTheme.accent, in: Capsule())
                .shadow(color: AppTheme.accent.opacity(0.35), radius: 12, y: 6)
            }
            .buttonStyle(ScaleButtonStyle())
        }
        .padding(.horizontal, 40)
    }
}

// MARK: - Salary Card

struct SalaryCard: View {
    let schedule: SalarySchedule
    let allSchedules: [SalarySchedule]
    let cards: [BankCard]
    @Bindable var vm: SalaryViewModel
    let context: ModelContext

    @State private var showActions = false
    @State private var showDeleteConfirm = false

    private var nextDate: Date { SalaryDateEngine.nextPayDate(dayOfMonth: schedule.dayOfMonth) }
    private var daysLeft: Int  { SalaryDateEngine.daysUntilPay(dayOfMonth: schedule.dayOfMonth) }
    private var adjusted: Bool { SalaryDateEngine.wasAdjusted(intended: schedule.dayOfMonth, actual: nextDate) }
    private var upcoming: [Date] { SalaryDateEngine.upcomingDates(dayOfMonth: schedule.dayOfMonth, count: 4) }

    private var creditedThisMonth: Bool {
        let cal = Calendar.current
        let now = Date()
        return schedule.lastCreditedMonth == cal.component(.month, from: now) &&
               schedule.lastCreditedYear  == cal.component(.year,  from: now)
    }

    private var daysLabel: String {
        if daysLeft == 0 { return loc("salary.today_short") }
        if daysLeft == 1 { return loc("salary.tomorrow_short") }
        return String(format: loc("salary.in_days"), daysLeft)
    }

    private var daysColor: Color {
        if daysLeft == 0 { return AppTheme.accent }
        if daysLeft <= 3 { return AppTheme.orange }
        return AppTheme.textSecondary
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                // Header row
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(schedule.label)
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(AppTheme.textPrimary)
                            if schedule.isPinned {
                                Image(systemName: "pin.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(AppTheme.accent)
                                    .transition(.scale.combined(with: .opacity))
                            }
                            if !schedule.isActive {
                                Text(loc("salary.paused"))
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(AppTheme.textSecondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(AppTheme.cardMid, in: Capsule())
                            }
                        }
                        Text(String(format: loc("salary.every_day"), schedule.dayOfMonth))
                            .font(.system(size: 13))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                    Spacer()

                    // FIXED: plain button -> confirmationDialog, no Menu
                    Button {
                        HapticManager.shared.tap()
                        showActions = true
                    } label: {
                        ZStack {
                            Circle()
                                .fill(AppTheme.cardMid)
                                .frame(width: 44, height: 44)
                            Image(systemName: "ellipsis")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                        .contentShape(Circle())
                    }
                    .buttonStyle(ScaleButtonStyle())
                }

                // Amount + countdown
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(loc("common.amount"))
                            .font(.system(size: 11))
                            .foregroundStyle(AppTheme.textSecondary)
                        Text(CurrencyManager.shared.formatted(schedule.amount, currency: schedule.currency))
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(AppTheme.textPrimary)
                            .contentTransition(.numericText())
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(loc("salary.next_payday"))
                            .font(.system(size: 11))
                            .foregroundStyle(AppTheme.textSecondary)
                        Text(daysLabel)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(daysColor)
                    }
                }

                // Pay date row
                HStack(spacing: 8) {
                    Image(systemName: creditedThisMonth ? "checkmark.circle.fill" : "calendar")
                        .font(.system(size: 13))
                        .foregroundStyle(creditedThisMonth ? AppTheme.accent : AppTheme.accent)
                    Text(creditedThisMonth
                         ? String(format: loc("salary.credited_on"), nextDate.displayDate)
                         : nextDate.displayDate)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AppTheme.textPrimary)
                    if adjusted && !creditedThisMonth {
                        Text(loc("home.adjusted"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(AppTheme.orange)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(AppTheme.orange.opacity(0.15), in: Capsule())
                            .overlay(Capsule().stroke(AppTheme.orange.opacity(0.3), lineWidth: 1))
                    }
                    if creditedThisMonth {
                        Text(loc("salary.paid"))
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(AppTheme.bg)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3)
                            .background(AppTheme.accent, in: Capsule())
                    }
                    Spacer()
                }
                .padding(12)
                .background(
                    creditedThisMonth ? AppTheme.accent.opacity(0.1) : AppTheme.accent.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 12)
                )
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .stroke(creditedThisMonth ? AppTheme.accent.opacity(0.4) : AppTheme.accent.opacity(0.15), lineWidth: 1))
            }
            .padding(18)

            Divider().background(AppTheme.cardMid)

            // Details navigation
            NavigationLink(destination: SalaryDetailView(schedule: schedule)) {
                HStack {
                    Text(loc("salary.view_schedule"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AppTheme.accent)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)

            Divider().background(AppTheme.cardMid)

            // Upcoming strip
            VStack(alignment: .leading, spacing: 12) {
                Text(loc("salary.upcoming"))
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.textSecondary)
                    .padding(.horizontal, 18)
                    .padding(.top, 14)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(upcoming, id: \.self) { date in
                            UpcomingPayPill(
                                date: date,
                                intended: schedule.dayOfMonth,
                                currency: schedule.currency,
                                amount: schedule.amount
                            )
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 16)
                }
            }
        }
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20)
            .stroke(daysLeft == 0 ? AppTheme.accent.opacity(0.4) : Color.clear, lineWidth: 1.5))
        // Action sheet (works reliably on real device)
        .confirmationDialog(schedule.label, isPresented: $showActions, titleVisibility: .visible) {
            Button(loc("common.edit")) { vm.loadForEdit(schedule, cards: cards) }
            Button(schedule.isPinned ? loc("salary.unpin") : loc("salary.pin")) {
                if !schedule.isPinned {
                    for s in allSchedules where s.id != schedule.id { s.isPinned = false }
                }
                schedule.isPinned.toggle()
                try? context.save()
                HapticManager.shared.tap()
            }
            Button(schedule.isActive ? loc("salary.pause") : loc("salary.resume")) {
                schedule.isActive.toggle()
                try? context.save()
            }
            Button(loc("common.delete"), role: .destructive) { showDeleteConfirm = true }
            Button(loc("common.cancel"), role: .cancel) {}
        }
        .confirmationDialog(String(format: loc("salary.delete_title"), schedule.label),
                            isPresented: $showDeleteConfirm,
                            titleVisibility: .visible) {
            Button(loc("common.delete"), role: .destructive) {
                context.delete(schedule)
                try? context.save()
                HapticManager.shared.warning()
            }
            Button(loc("common.cancel"), role: .cancel) {}
        } message: {
            Text(loc("salary.delete_confirm"))
        }
    }
}

// MARK: - Upcoming Pay Pill

struct UpcomingPayPill: View {
    let date: Date
    let intended: Int
    let currency: String
    let amount: Double

    private var isToday:     Bool { SalaryDateEngine.isToday(date) }
    private var wasAdjusted: Bool { SalaryDateEngine.wasAdjusted(intended: intended, actual: date) }
    private var locale:      Locale { LanguageManager.shared.currentLocale }
    private var monthLabel:  String {
        let df = DateFormatter(); df.locale = locale; df.dateFormat = "MMM"
        return df.string(from: date)
    }
    private var dayLabel:    String {
        let df = DateFormatter(); df.locale = locale; df.dateFormat = "d"
        return df.string(from: date)
    }
    private var weekday:     String {
        let df = DateFormatter(); df.locale = locale; df.dateFormat = "EEE"
        return df.string(from: date)
    }

    var body: some View {
        VStack(spacing: 6) {
            Text(monthLabel.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isToday ? AppTheme.bg : AppTheme.textSecondary)
                .tracking(0.8)
            Text(dayLabel)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(isToday ? AppTheme.bg : AppTheme.textPrimary)
            Text(weekday)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isToday ? AppTheme.bg.opacity(0.7) : AppTheme.textSecondary)
            if wasAdjusted {
                Image(systemName: "arrow.left.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(isToday ? AppTheme.bg.opacity(0.8) : AppTheme.orange)
            } else {
                Spacer().frame(height: 12)
            }
        }
        .frame(width: 64)
        .padding(.vertical, 12)
        .background(isToday ? AppTheme.accent : AppTheme.cardMid,
                    in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .stroke(wasAdjusted && !isToday ? AppTheme.orange.opacity(0.4) : Color.clear, lineWidth: 1))
        .shadow(color: isToday ? AppTheme.accent.opacity(0.3) : .clear, radius: 8, y: 4)
    }
}

// MARK: - Salary Form Sheet

struct SalaryFormSheet: View {
    @Bindable var vm: SalaryViewModel
    let context: ModelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \BankCard.sortOrder) private var cards: [BankCard]
    @State private var appeared = false

    private var isEditing: Bool { vm.editingSchedule != nil }

    private var previewDate: Date {
        let cal = Calendar.current
        let month = cal.component(.month, from: .now)
        let year  = cal.component(.year, from: .now)
        return SalaryDateEngine.actualPayDate(dayOfMonth: vm.formDay,
                                              month: month, year: year)
    }

    private var previewAdjusted: Bool {
        SalaryDateEngine.wasAdjusted(intended: vm.formDay, actual: previewDate)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 22) {

                        SheetField(label: loc("salary.label"),
                                   placeholder: loc("salary.label_placeholder"),
                                   text: $vm.formLabel)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 20)

                        // Amount + currency
                        VStack(spacing: 8) {
                            Text(loc("salary.amount"))
                                .font(.system(size: 13))
                                .foregroundStyle(AppTheme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 22)

                            HStack(spacing: 10) {
                                // Locked to card currency when a card is selected
                                if let cardID = vm.formCardID,
                                   let card = cards.first(where: { $0.id == cardID }) {
                                    HStack(spacing: 6) {
                                        Text(card.currency)
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundStyle(AppTheme.textPrimary)
                                        Image(systemName: "lock.fill")
                                            .font(.system(size: 10))
                                            .foregroundStyle(AppTheme.textSecondary)
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 14)
                                    .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
                                } else {
                                    Menu {
                                        ForEach(vm.currencies, id: \.self) { c in
                                            Button(c) {
                                                HapticManager.shared.tap()
                                                vm.formCurrency = c
                                            }
                                        }
                                    } label: {
                                        HStack(spacing: 6) {
                                            Text(vm.formCurrency)
                                                .font(.system(size: 15, weight: .semibold))
                                                .foregroundStyle(AppTheme.textPrimary)
                                            Image(systemName: "chevron.up.chevron.down")
                                                .font(.system(size: 10))
                                                .foregroundStyle(AppTheme.textSecondary)
                                        }
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 14)
                                        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
                                    }
                                }

                                TextField("0", text: $vm.formAmount)
                                    .font(.system(size: 22, weight: .bold))
                                    .foregroundStyle(AppTheme.textPrimary)
                                    .keyboardType(.decimalPad)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 14)
                                    .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
                                    .frame(maxWidth: .infinity)
                            }
                            .padding(.horizontal, 22)
                        }
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 20)
                        .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.1), value: appeared)

                        // Day stepper
                        VStack(spacing: 8) {
                            Text(loc("salary.intended"))
                                .font(.system(size: 13))
                                .foregroundStyle(AppTheme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 22)

                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(String(format: loc("salary.day_of"), vm.formDay))
                                        .font(.system(size: 17, weight: .semibold))
                                        .foregroundStyle(AppTheme.textPrimary)
                                    Text(loc("salary.contracted"))
                                        .font(.system(size: 12))
                                        .foregroundStyle(AppTheme.textSecondary)
                                }
                                Spacer()
                                HStack(spacing: 0) {
                                    Button {
                                        HapticManager.shared.tap()
                                        if vm.formDay > 1 { vm.formDay -= 1 }
                                    } label: {
                                        Image(systemName: "minus")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(AppTheme.textPrimary)
                                            .frame(width: 40, height: 40)
                                    }
                                    Text("\(vm.formDay)")
                                        .font(.system(size: 20, weight: .bold))
                                        .foregroundStyle(AppTheme.accent)
                                        .frame(width: 44)
                                        .contentTransition(.numericText())
                                    Button {
                                        HapticManager.shared.tap()
                                        if vm.formDay < 31 { vm.formDay += 1 }
                                    } label: {
                                        Image(systemName: "plus")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(AppTheme.textPrimary)
                                            .frame(width: 40, height: 40)
                                    }
                                }
                                .background(AppTheme.cardMid, in: RoundedRectangle(cornerRadius: 12))
                            }
                            .padding(16)
                            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 16))
                            .padding(.horizontal, 22)
                        }
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 20)
                        .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.15), value: appeared)

                        // Card picker — REQUIRED: which card receives salary
                        VStack(spacing: 8) {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .font(.system(size: 12)).foregroundStyle(AppTheme.orange)
                                Text(loc("salary.choose_card"))
                                    .font(.system(size: 12, weight: .medium)).foregroundStyle(AppTheme.orange)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 22)

                            CardPickerSection(selectedCardID: $vm.formCardID)
                        }
                        .onChange(of: vm.formCardID) { _, newID in
                            if let id = newID, let card = cards.first(where: { $0.id == id }) {
                                vm.formCurrency = card.currency
                            }
                        }
                        .opacity(appeared ? 1 : 0)
                        .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.18), value: appeared)

                        // Live preview
                        VStack(spacing: 8) {
                            Text(loc("salary.actual_this"))
                                .font(.system(size: 13))
                                .foregroundStyle(AppTheme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 22)

                            HStack(spacing: 12) {
                                Image(systemName: previewAdjusted
                                      ? "arrow.left.circle.fill"
                                      : "checkmark.circle.fill")
                                    .font(.system(size: 20))
                                    .foregroundStyle(previewAdjusted ? AppTheme.orange : AppTheme.accent)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(previewDate.formatted(
                                        .dateTime
                                            .day()
                                            .month()
                                            .year()
                                    ))
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(AppTheme.textPrimary)
                                    if previewAdjusted {
                                        Text(String(format: loc("salary.moved"), vm.formDay))
                                            .font(.system(size: 12))
                                            .foregroundStyle(AppTheme.orange)
                                    } else {
                                        Text(loc("cards.falls_regular"))
                                            .font(.system(size: 12))
                                            .foregroundStyle(AppTheme.textSecondary)
                                    }
                                }
                                Spacer()
                            }
                            .padding(14)
                            .background(
                                (previewAdjusted ? AppTheme.orange : AppTheme.accent).opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 14)
                            )
                            .overlay(RoundedRectangle(cornerRadius: 14)
                                .stroke((previewAdjusted ? AppTheme.orange : AppTheme.accent).opacity(0.2),
                                        lineWidth: 1))
                            .padding(.horizontal, 22)
                            .animation(.spring(response: 0.3), value: vm.formDay)
                        }
                        .opacity(appeared ? 1 : 0)
                        .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.2), value: appeared)

                        if let err = vm.formError {
                            Text(err)
                                .font(.system(size: 13))
                                .foregroundStyle(AppTheme.red)
                                .padding(.horizontal, 22)
                                .transition(.opacity)
                        }

                        // Info banner
                        if !isEditing {
                            HStack(spacing: 10) {
                                Image(systemName: "info.circle.fill")
                                    .font(.system(size: 16))
                                    .foregroundStyle(AppTheme.blue)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(loc("salary.auto_note"))
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(AppTheme.textPrimary)
                                    Text(loc("salary.auto_note_sub"))
                                        .font(.system(size: 12))
                                        .foregroundStyle(AppTheme.textSecondary)
                                        .lineSpacing(2)
                                }
                            }
                            .padding(14)
                            .background(AppTheme.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(AppTheme.blue.opacity(0.2), lineWidth: 1))
                            .padding(.horizontal, 22)
                            .opacity(appeared ? 1 : 0)
                            .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.22), value: appeared)
                        }

                        Button { save() } label: {
                            Text(isEditing ? loc("common.save") : loc("salary.add"))
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(AppTheme.bg)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(cards.isEmpty ? AppTheme.textSecondary.opacity(0.3) : AppTheme.accent, in: Capsule())
                                .shadow(color: cards.isEmpty ? .clear : AppTheme.accent.opacity(0.35), radius: 12, y: 6)
                        }
                        .buttonStyle(ScaleButtonStyle())
                        .disabled(cards.isEmpty)
                        .padding(.horizontal, 22)
                        .padding(.top, 6)
                        .opacity(appeared ? 1 : 0)
                        .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.25), value: appeared)

                        Spacer(minLength: 40)
                    }
                    .padding(.top, 8)
                }
            }
            .navigationTitle(isEditing ? loc("salary.edit") : loc("salary.new"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc("common.cancel")) {
                        HapticManager.shared.tap()
                        dismiss()
                    }
                    .foregroundStyle(AppTheme.textSecondary)
                }

            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.1)) { appeared = true }
        }
    }

    private func save() {
        guard vm.validate() else { HapticManager.shared.error(); return }
        let amount = Double(vm.formAmount) ?? 0
        if let existing = vm.editingSchedule {
            existing.label      = vm.formLabel.trimmingCharacters(in: .whitespaces)
            existing.amount     = amount
            existing.dayOfMonth = vm.formDay
            existing.currency   = vm.formCurrency
            existing.cardID     = vm.formCardID
        } else {
            let cal = Calendar.current
            let now = Date()
            let schedule = SalarySchedule(
                label: vm.formLabel.trimmingCharacters(in: .whitespaces),
                amount: amount,
                dayOfMonth: vm.formDay,
                currency: vm.formCurrency,
                cardID: vm.formCardID
            )
            // Skip the current month — user should add this month's income manually
            schedule.lastCreditedMonth = cal.component(.month, from: now)
            schedule.lastCreditedYear  = cal.component(.year, from: now)
            context.insert(schedule)
        }
        try? context.save()
        HapticManager.shared.success()

        // ✅ Schedule 3-day and 1-day advance device + in-app notifications
        let savedLabel  = vm.formLabel.trimmingCharacters(in: .whitespaces)
        let savedDay    = vm.formDay
        let savedAmount = vm.formAmount
        let savedCurrency = vm.formCurrency
        Task { @MainActor in
            NotificationManager.scheduleSalaryReminders(
                dayOfMonth: savedDay,
                label:      savedLabel,
                amount:     "\(savedCurrency) \(savedAmount)"
            )
        }

        dismiss()
    }
}

// MARK: - Card Picker Section

struct CardPickerSection: View {
    @Binding var selectedCardID: UUID?
    @Query(sort: \BankCard.sortOrder) private var cards: [BankCard]

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(loc("salary.credit_to"))
                    .font(.system(size: 13))
                    .foregroundStyle(AppTheme.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 22)

            if cards.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "creditcard.trianglebadge.exclamationmark")
                        .font(.system(size: 14)).foregroundStyle(AppTheme.orange)
                    Text(loc("home.add_card_salary"))
                        .font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
                }
                .padding(14)
                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 22)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(cards) { card in
                            let isSelected = selectedCardID == card.id
                            Button { HapticManager.shared.tap(); selectedCardID = card.id } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    ZStack(alignment: .topLeading) {
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(LinearGradient(
                                                colors: [Color(hex: card.gradientStart), Color(hex: card.gradientEnd)],
                                                startPoint: .topLeading, endPoint: .bottomTrailing))
                                            .frame(width: 80, height: 48)
                                            .overlay(RoundedRectangle(cornerRadius: 10)
                                                .stroke(isSelected ? AppTheme.accent : Color.clear, lineWidth: 2))
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("•••• \(card.cardNumber.suffix(4))")
                                                .font(.system(size: 9, weight: .semibold)).foregroundStyle(.white)
                                            Text(card.holderName).font(.system(size: 8))
                                                .foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                                        }
                                        .padding(6)
                                        if isSelected {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.system(size: 13)).foregroundStyle(AppTheme.accent)
                                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                                                .padding(5)
                                        }
                                    }
                                    Text(isSelected ? loc("salary.selected") : CardNetwork.detect(from: card.cardNumber).name)
                                        .font(.system(size: 9)).foregroundStyle(isSelected ? AppTheme.accent : AppTheme.textSecondary)
                                }
                                .frame(width: 80)
                            }
                            .buttonStyle(ScaleButtonStyle())
                        }
                    }
                    .padding(.horizontal, 22)
                }

                if selectedCardID == nil {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 12)).foregroundStyle(AppTheme.orange)
                        Text(loc("salary.tap_select"))
                            .font(.system(size: 12)).foregroundStyle(AppTheme.orange)
                    }.padding(.horizontal, 22)
                } else if let id = selectedCardID, let card = cards.first(where: { $0.id == id }) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(AppTheme.accent)
                        Text(String(format: loc("salary.credited_indicator"), card.last4)).font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
                    }.padding(.horizontal, 22)
                }
            }
        }
    }
}
// MARK: - Salary Detail View

struct SalaryDetailView: View {
    let schedule: SalarySchedule
    @Query(sort: \BankCard.sortOrder) private var cards: [BankCard]
    @State private var appeared = false

    private var linkedCard: BankCard? { cards.first(where: { $0.id == schedule.cardID }) }
    private var upcoming12: [Date]    { SalaryDateEngine.upcomingDates(dayOfMonth: schedule.dayOfMonth, count: 12) }
    private var nextDate: Date        { SalaryDateEngine.nextPayDate(dayOfMonth: schedule.dayOfMonth) }
    private var daysLeft: Int         { SalaryDateEngine.daysUntilPay(dayOfMonth: schedule.dayOfMonth) }

    private var creditedThisMonth: Bool {
        let cal = Calendar.current; let now = Date()
        return schedule.lastCreditedMonth == cal.component(.month, from: now) &&
               schedule.lastCreditedYear  == cal.component(.year,  from: now)
    }

    var body: some View {
        ZStack {
            AppTheme.bg.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 20) {

                    // Hero card
                    VStack(spacing: 16) {
                        HStack(spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 14).fill(AppTheme.accent.opacity(0.12)).frame(width: 54, height: 54)
                                Image(systemName: "banknote.fill").font(.system(size: 24)).foregroundStyle(AppTheme.accent)
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text(schedule.label).font(.system(size: 18, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                                HStack(spacing: 6) {
                                    Text(String(format: loc("salary.every_day"), schedule.dayOfMonth))
                                        .font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
                                    if !schedule.isActive {
                                        Text(loc("salary.paused")).font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(AppTheme.textSecondary)
                                            .padding(.horizontal, 7).padding(.vertical, 2)
                                            .background(AppTheme.cardMid, in: Capsule())
                                    }
                                }
                            }
                            Spacer()
                        }

                        Divider().background(AppTheme.cardMid)

                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(loc("common.amount")).font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
                                Text(CurrencyManager.shared.formatted(schedule.amount, currency: schedule.currency))
                                    .font(.system(size: 22, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 3) {
                                Text(loc("salary.next_payday")).font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
                                Text(daysLeft == 0 ? loc("salary.today_short") : daysLeft == 1 ? loc("salary.tomorrow_short") : String(format: loc("salary.in_days"), daysLeft))
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundStyle(daysLeft == 0 ? AppTheme.accent : daysLeft <= 3 ? AppTheme.orange : AppTheme.textPrimary)
                            }
                        }

                        // Next pay date row
                        HStack(spacing: 8) {
                            Image(systemName: creditedThisMonth ? "checkmark.circle.fill" : "calendar")
                                .font(.system(size: 13)).foregroundStyle(creditedThisMonth ? AppTheme.accent : AppTheme.accent)
                            Text(creditedThisMonth
                                 ? loc("salary.credited_this_month")
                                 : nextDate.displayDate)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(AppTheme.textPrimary)
                            if SalaryDateEngine.wasAdjusted(intended: schedule.dayOfMonth, actual: nextDate) && !creditedThisMonth {
                                Text(loc("home.adjusted")).font(.system(size: 11, weight: .semibold)).foregroundStyle(AppTheme.orange)
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(AppTheme.orange.opacity(0.15), in: Capsule())
                            }
                            Spacer()
                            if creditedThisMonth {
                                Text(loc("salary.paid")).font(.system(size: 11, weight: .bold)).foregroundStyle(AppTheme.bg)
                                    .padding(.horizontal, 10).padding(.vertical, 3).background(AppTheme.accent, in: Capsule())
                            }
                        }
                        .padding(12)
                        .background(AppTheme.accent.opacity(creditedThisMonth ? 0.1 : 0.07), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppTheme.accent.opacity(creditedThisMonth ? 0.4 : 0.15), lineWidth: 1))
                    }
                    .padding(16)
                    .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(AppTheme.accent.opacity(0.2), lineWidth: 1))
                    .padding(.horizontal, 22)
                    .opacity(appeared ? 1 : 0).offset(y: appeared ? 0 : 20)
                    .animation(.spring(response: 0.55, dampingFraction: 0.8).delay(0.05), value: appeared)

                    // Linked card
                    if let card = linkedCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(loc("salary.credited_to")).font(.system(size: 13, weight: .semibold)).foregroundStyle(AppTheme.textSecondary)
                            HStack(spacing: 12) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(LinearGradient(colors: [Color(hex: card.gradientStart), Color(hex: card.gradientEnd)], startPoint: .leading, endPoint: .trailing))
                                        .frame(width: 56, height: 36)
                                    Text("•••• \(card.cardNumber.suffix(4))").font(.system(size: 9, weight: .semibold)).foregroundStyle(.white)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(card.holderName).font(.system(size: 14, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                                    Text(card.currency).font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
                                }
                                Spacer()
                                Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).foregroundStyle(AppTheme.accent)
                            }
                            .padding(12)
                            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
                        }
                        .padding(.horizontal, 22)
                        .opacity(appeared ? 1 : 0).offset(y: appeared ? 0 : 20)
                        .animation(.spring(response: 0.55, dampingFraction: 0.8).delay(0.1), value: appeared)
                    }

                    // Upcoming 12 months
                    VStack(alignment: .leading, spacing: 12) {
                        Text(loc("salary.upcoming_12"))
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                            .padding(.horizontal, 22)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(upcoming12, id: \.self) { date in
                                    let isToday = SalaryDateEngine.isToday(date)
                                    let wasAdj  = SalaryDateEngine.wasAdjusted(intended: schedule.dayOfMonth, actual: date)
                                    let locale  = LanguageManager.shared.currentLocale
                                    let monthLabel: String = {
                                        let df = DateFormatter(); df.locale = locale; df.dateFormat = "MMM"
                                        return df.string(from: date)
                                    }()
                                    let dayLabel: String = {
                                        let df = DateFormatter(); df.locale = locale; df.dateFormat = "d"
                                        return df.string(from: date)
                                    }()
                                    let weekday: String = {
                                        let df = DateFormatter(); df.locale = locale; df.dateFormat = "EEE"
                                        return df.string(from: date)
                                    }()
                                    VStack(spacing: 6) {
                                        Text(monthLabel.uppercased())
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(isToday ? AppTheme.bg : AppTheme.textSecondary).tracking(0.8)
                                        Text(dayLabel)
                                            .font(.system(size: 22, weight: .bold))
                                            .foregroundStyle(isToday ? AppTheme.bg : AppTheme.textPrimary)
                                        Text(weekday)
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(isToday ? AppTheme.bg.opacity(0.7) : AppTheme.textSecondary)
                                        if wasAdj {
                                            Image(systemName: "arrow.left.circle.fill").font(.system(size: 12))
                                                .foregroundStyle(isToday ? AppTheme.bg.opacity(0.8) : AppTheme.orange)
                                        } else {
                                            Spacer().frame(height: 12)
                                        }
                                    }
                                    .frame(width: 64).padding(.vertical, 12)
                                    .background(isToday ? AppTheme.accent : AppTheme.cardMid, in: RoundedRectangle(cornerRadius: 14))
                                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(wasAdj && !isToday ? AppTheme.orange.opacity(0.4) : Color.clear, lineWidth: 1))
                                    .shadow(color: isToday ? AppTheme.accent.opacity(0.3) : .clear, radius: 8, y: 4)
                                }
                            }
                            .padding(.horizontal, 22)
                        }

                        // Adjustment legend
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.left.circle.fill").font(.system(size: 11)).foregroundStyle(AppTheme.orange)
                            Text(loc("salary.adjusted_legend")).font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
                        }
                        .padding(.horizontal, 22)
                    }
                    .opacity(appeared ? 1 : 0).offset(y: appeared ? 0 : 20)
                    .animation(.spring(response: 0.55, dampingFraction: 0.8).delay(0.15), value: appeared)

                    Spacer(minLength: 40)
                }
                .padding(.top, 16)
            }
        }
        .navigationTitle(schedule.label)
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(AppTheme.bg, for: .navigationBar)
        .onAppear { withAnimation(.spring(response: 0.55, dampingFraction: 0.8)) { appeared = true } }
    }
}
