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

    init(label: String, amount: Double, dayOfMonth: Int,
         currency: String = "USD", cardID: UUID? = nil) {
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
    }
}

// MARK: - Salary Date Engine

struct SalaryDateEngine {

    static let publicHolidays: Set<String> = [
        "01-01", "01-29", "02-09",
        "03-29", "03-31",
        "04-18",
        "05-01", "05-12", "05-29",
        "06-01", "06-06",
        "06-27",
        "08-17",
        "09-05",
        "12-25", "12-26"
    ]

    static func actualPayDate(dayOfMonth: Int, month: Int, year: Int) -> Date {
        let cal = Calendar.current
        var components = DateComponents(year: year, month: month, day: dayOfMonth)
        let lastDay = cal.range(of: .day, in: .month,
                                for: cal.date(from: components)!)!.count
        components.day = min(dayOfMonth, lastDay)
        guard var date = cal.date(from: components) else { return .now }
        while !isBusinessDay(date, cal: cal) {
            date = cal.date(byAdding: .day, value: -1, to: date)!
        }
        return date
    }

    static func isBusinessDay(_ date: Date, cal: Calendar) -> Bool {
        let weekday = cal.component(.weekday, from: date)
        guard weekday != 1 && weekday != 7 else { return false }
        let month = cal.component(.month, from: date)
        let day   = cal.component(.day, from: date)
        let key   = String(format: "%02d-%02d", month, day)
        return !publicHolidays.contains(key)
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
    var formCurrency: String = "USD"
    var formError: String? = nil

    let currencies = ["USD", "IDR", "EUR", "GBP", "SGD", "MYR", "JPY"]

    func resetForm() {
        formLabel    = ""
        formAmount   = ""
        formDay      = 25
        formCurrency = "USD"
        formError    = nil
        editingSchedule = nil
    }

    func loadForEdit(_ s: SalarySchedule) {
        formLabel    = s.label
        formAmount   = String(s.amount)
        formDay      = s.dayOfMonth
        formCurrency = s.currency
        editingSchedule = s
        showAddSheet = true
    }

    func validate() -> Bool {
        guard !formLabel.trimmingCharacters(in: .whitespaces).isEmpty else {
            formError = "Enter a label"; return false
        }
        guard let amt = Double(formAmount), amt > 0 else {
            formError = "Enter a valid amount"; return false
        }
        formError = nil
        return true
    }
}

// MARK: - Salary Main View

struct SalaryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \SalarySchedule.createdAt) private var schedules: [SalarySchedule]
    @State private var vm = SalaryViewModel()
    @State private var appeared = false

    var body: some View {
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
                                SalaryCard(schedule: schedule, vm: vm, context: context)
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
        }
    }
}

// MARK: - Nav Bar

struct SalaryNavBar: View {
    @Bindable var vm: SalaryViewModel
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Salary")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text("Smart payday scheduler")
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
                        .fill(AppTheme.accent)
                        .frame(width: 42, height: 42)
                        .shadow(color: AppTheme.accent.opacity(0.4), radius: 10, y: 4)
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(AppTheme.bg)
                }
            }
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
                Text("No salary set up yet")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text("Add your salary schedule and we'll\nalways show your real payday.")
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
                    Text("Add Salary").font(.system(size: 15, weight: .semibold))
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
    @Bindable var vm: SalaryViewModel
    let context: ModelContext

    @State private var showActions = false
    @State private var showDeleteConfirm = false

    private var nextDate: Date { SalaryDateEngine.nextPayDate(dayOfMonth: schedule.dayOfMonth) }
    private var daysLeft: Int  { SalaryDateEngine.daysUntilPay(dayOfMonth: schedule.dayOfMonth) }
    private var adjusted: Bool { SalaryDateEngine.wasAdjusted(intended: schedule.dayOfMonth, actual: nextDate) }
    private var upcoming: [Date] { SalaryDateEngine.upcomingDates(dayOfMonth: schedule.dayOfMonth, count: 4) }

    private var daysLabel: String {
        if daysLeft == 0 { return "Today!" }
        if daysLeft == 1 { return "Tomorrow" }
        return "In \(daysLeft) days"
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
                            if !schedule.isActive {
                                Text("Paused")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(AppTheme.textSecondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(AppTheme.cardMid, in: Capsule())
                            }
                        }
                        Text("Every \(ordinal(schedule.dayOfMonth)) of the month")
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
                        Text("Amount")
                            .font(.system(size: 11))
                            .foregroundStyle(AppTheme.textSecondary)
                        Text("\(schedule.currency) \(formattedAmount(schedule.amount))")
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(AppTheme.textPrimary)
                            .contentTransition(.numericText())
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("Next payday")
                            .font(.system(size: 11))
                            .foregroundStyle(AppTheme.textSecondary)
                        Text(daysLabel)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(daysColor)
                    }
                }

                // Pay date row
                HStack(spacing: 8) {
                    Image(systemName: "calendar")
                        .font(.system(size: 13))
                        .foregroundStyle(AppTheme.accent)
                    Text(nextDate.formatted(date: .complete, time: .omitted))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AppTheme.textPrimary)
                    if adjusted {
                        Text("adjusted")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(AppTheme.orange)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(AppTheme.orange.opacity(0.15), in: Capsule())
                            .overlay(Capsule().stroke(AppTheme.orange.opacity(0.3), lineWidth: 1))
                    }
                    Spacer()
                }
                .padding(12)
                .background(AppTheme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .stroke(AppTheme.accent.opacity(0.15), lineWidth: 1))
            }
            .padding(18)

            Divider().background(AppTheme.cardMid)

            // Upcoming strip
            VStack(alignment: .leading, spacing: 12) {
                Text("Upcoming paydays")
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
            Button("Edit") { vm.loadForEdit(schedule) }
            Button(schedule.isActive ? "Pause" : "Resume") {
                schedule.isActive.toggle()
                try? context.save()
            }
            Button("Delete", role: .destructive) { showDeleteConfirm = true }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete \(schedule.label)?",
                            isPresented: $showDeleteConfirm,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                context.delete(schedule)
                try? context.save()
                HapticManager.shared.warning()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove the salary schedule permanently.")
        }
    }

    private func ordinal(_ n: Int) -> String {
        let suffix: String
        switch n % 10 {
        case 1 where n % 100 != 11: suffix = "st"
        case 2 where n % 100 != 12: suffix = "nd"
        case 3 where n % 100 != 13: suffix = "rd"
        default: suffix = "th"
        }
        return "\(n)\(suffix)"
    }

    private func formattedAmount(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 0
        f.groupingSeparator = ","
        return f.string(from: NSNumber(value: v)) ?? "\(Int(v))"
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
    private var monthLabel:  String { date.formatted(.dateTime.month(.abbreviated)) }
    private var dayLabel:    String { date.formatted(.dateTime.day()) }
    private var weekday:     String { date.formatted(.dateTime.weekday(.abbreviated)) }

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

                        SheetField(label: "Salary label",
                                   placeholder: "e.g. Main Job, Freelance, Part-time",
                                   text: $vm.formLabel)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 20)

                        // Amount + currency
                        VStack(spacing: 8) {
                            Text("Amount & Currency")
                                .font(.system(size: 13))
                                .foregroundStyle(AppTheme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 22)

                            HStack(spacing: 10) {
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
                            Text("Intended payday")
                                .font(.system(size: 13))
                                .foregroundStyle(AppTheme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 22)

                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Day \(vm.formDay) of every month")
                                        .font(.system(size: 17, weight: .semibold))
                                        .foregroundStyle(AppTheme.textPrimary)
                                    Text("The date you're contracted to be paid")
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

                        // Live preview
                        VStack(spacing: 8) {
                            Text("This month's actual payday")
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
                                    Text(previewDate.formatted(date: .complete, time: .omitted))
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(AppTheme.textPrimary)
                                    if previewAdjusted {
                                        Text("Moved earlier - day \(vm.formDay) is a weekend or holiday")
                                            .font(.system(size: 12))
                                            .foregroundStyle(AppTheme.orange)
                                    } else {
                                        Text("Falls on a regular business day")
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

                        Button { save() } label: {
                            Text(isEditing ? "Save Changes" : "Add Salary Schedule")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(AppTheme.bg)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(AppTheme.accent, in: Capsule())
                                .shadow(color: AppTheme.accent.opacity(0.35), radius: 12, y: 6)
                        }
                        .buttonStyle(ScaleButtonStyle())
                        .padding(.horizontal, 22)
                        .padding(.top, 6)
                        .opacity(appeared ? 1 : 0)
                        .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.25), value: appeared)

                        Spacer(minLength: 40)
                    }
                    .padding(.top, 8)
                }
            }
            .navigationTitle(isEditing ? "Edit Salary" : "New Salary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
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
        } else {
            let schedule = SalarySchedule(
                label: vm.formLabel.trimmingCharacters(in: .whitespaces),
                amount: amount,
                dayOfMonth: vm.formDay,
                currency: vm.formCurrency
            )
            context.insert(schedule)
        }
        try? context.save()
        HapticManager.shared.success()
        dismiss()
    }
}
