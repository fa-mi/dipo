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
    /// When true, the credit engine auto-creates an income transaction on
    /// payday. When false, the schedule still shows upcoming paydays (planning)
    /// but records NOTHING — for users who receive salary on an account not
    /// tracked in DiPo, or who prefer to log income manually. Defaults to true
    /// so existing schedules keep their current auto-record behavior (SwiftData
    /// lightweight migration fills this in for older rows).
    var autoRecord: Bool = true

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
        self.autoRecord = true
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
            // Only dates still ahead. This also accepted the FIRST date
            // unconditionally, so after the 25th this month's payday led the
            // "upcoming" row even though it had already passed.
            if d >= cal.startOfDay(for: now) {
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
    var formAutoRecord: Bool = true
    var formError: String? = nil

    let currencies = ["USD", "IDR"]

    func resetForm() {
        formLabel    = ""
        formAmount   = ""
        formDay      = 25
        formCurrency = CurrencyManager.shared.preferredCurrency
        // Default to the account the rest of the app budgets against. Salary
        // landing on a card other than the main one is why Statistics could
        // show a pay cycle with no salary in it: the credit engine posted the
        // income somewhere Smart Budget was not looking. Still editable — some
        // people genuinely are paid into a second account — but the default
        // should be the one that keeps every screen agreeing.
        formCardID   = MainCard.id.flatMap(UUID.init(uuidString:))
        formAutoRecord = true
        formError    = nil
        editingSchedule = nil
    }

    func loadForEdit(_ s: SalarySchedule, cards: [BankCard]) {
        formLabel  = s.label
        // "10000000", not "10000000.0" — the amount field shows it at 34pt.
        formAmount = s.amount.rounded() == s.amount ? String(Int64(s.amount)) : String(s.amount)
        formDay    = s.dayOfMonth
        formCardID = s.cardID
        formAutoRecord = s.autoRecord
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

// MARK: - Pay Cycle

/// Where a schedule stands between its last payday and its next one.
///
/// Every salary surface used to state only "In 12 days". A countdown answers
/// when, but not how far through the month's money someone is — and that is
/// what they are actually weighing when they check. Both ends are ACTUAL pay
/// dates (weekend/holiday-adjusted), the same ones the credit engine posts on.
struct SalaryCycle {
    let next: Date
    let previous: Date
    let daysLeft: Int
    let length: Int

    var elapsed: Int { max(length - daysLeft, 0) }
    var progress: Double { min(max(Double(elapsed) / Double(length), 0), 1) }

    init(dayOfMonth: Int) {
        let cal = Calendar.current
        next = SalaryDateEngine.nextPayDate(dayOfMonth: dayOfMonth)
        let m = cal.component(.month, from: next)
        let y = cal.component(.year, from: next)
        previous = SalaryDateEngine.actualPayDate(dayOfMonth: dayOfMonth,
                                                  month: m == 1 ? 12 : m - 1,
                                                  year: m == 1 ? y - 1 : y)
        daysLeft = SalaryDateEngine.daysUntilPay(dayOfMonth: dayOfMonth)
        length = max(cal.dateComponents([.day], from: cal.startOfDay(for: previous),
                                        to: cal.startOfDay(for: next)).day ?? 30, 1)
    }

    /// "12 days", "Tomorrow", "Payday today".
    var countdown: String {
        switch daysLeft {
        case 0:  return loc("salary.today_big")
        case 1:  return loc("salary.tomorrow_big")
        default: return String(format: loc("salary.days_big"), daysLeft)
        }
    }

    /// Green on payday, orange in the last three days, quiet otherwise.
    var tint: Color {
        if daysLeft == 0 { return AppTheme.accent }
        if daysLeft <= 3 { return AppTheme.orange }
        return AppTheme.textPrimary
    }
}

private enum SalaryFormat {
    static func date(_ d: Date, _ template: String) -> String {
        let df = DateFormatter()
        df.locale = LanguageManager.shared.currentLocale
        df.setLocalizedDateFormatFromTemplate(template)
        return df.string(from: d)
    }
}

// MARK: - Pay Cycle Bar

struct PayCycleBar: View {
    let cycle: SalaryCycle
    var showsEnds: Bool = true

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(AppTheme.cardMid)
                    Capsule()
                        .fill(AppTheme.accentFill)
                        .frame(width: max(g.size.width * cycle.progress, 8))
                }
            }
            .frame(height: 8)
            .animation(.spring(response: 0.6, dampingFraction: 0.85), value: cycle.progress)

            if showsEnds {
                HStack {
                    Text(SalaryFormat.date(cycle.previous, "d MMM"))
                    Spacer()
                    Text(String(format: loc("salary.cycle_day"), cycle.elapsed, cycle.length))
                        .fontWeight(.semibold)
                        .foregroundStyle(AppTheme.textPrimary)
                    Spacer()
                    Text(SalaryFormat.date(cycle.next, "d MMM"))
                }
                .font(.system(.caption2))
                .foregroundStyle(AppTheme.textSecondary)
            }
        }
    }
}

// MARK: - Payday Tile

/// One actual payday: month, day, weekday. An orange dot marks a date the
/// engine moved earlier for a weekend or public holiday — the dot, not a
/// border, so a row of four stays calm when two of them moved.
struct PaydayTile: View {
    let date: Date
    let intended: Int

    private var isToday: Bool { SalaryDateEngine.isToday(date) }
    private var moved: Bool { SalaryDateEngine.wasAdjusted(intended: intended, actual: date) }

    var body: some View {
        VStack(spacing: 3) {
            Text(SalaryFormat.date(date, "MMM").uppercased())
                .font(.system(.caption2, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(isToday ? AppTheme.onVividFill.opacity(0.75) : AppTheme.textSecondary)
            Text(SalaryFormat.date(date, "d"))
                .font(.system(.title3, weight: .bold))
                .foregroundStyle(isToday ? AppTheme.onVividFill : AppTheme.textPrimary)
            Text(SalaryFormat.date(date, "EEE"))
                .font(.system(.caption2, weight: .medium))
                .foregroundStyle(isToday ? AppTheme.onVividFill.opacity(0.75) : AppTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(isToday ? AppTheme.accentFill : AppTheme.cardMid.opacity(0.55),
                    in: RoundedRectangle(cornerRadius: AppRadius.md))
        .overlay(alignment: .topTrailing) {
            if moved {
                Circle().fill(AppTheme.orange).frame(width: 7, height: 7).padding(7)
            }
        }
    }
}

// MARK: - Cycle Role

/// What a salary has to do with the pay cycle, as far as the user can change it.
///
/// The cycle starts on the pinned salary's payday, or — nothing pinned — the
/// largest salary's. That rule made the "Cycle start" chip and its pin toggle
/// look broken: unpinning the largest salary left it the cycle start, and with
/// two salaries both paid on the 25th, pinning either one changed nothing at
/// all. So the chip and the action only appear when there is a real choice,
/// and each state says what the action will actually do.
enum SalaryCycleRole {
    /// No choice to make: this salary cannot start the cycle (paused, paid into
    /// another card) or every candidate is paid on the same day.
    case none
    /// Cycle start because it is the largest salary.
    case automaticStart
    /// Cycle start because the user pinned it.
    case pinnedStart
    /// Could start the cycle; currently it starts on `currentDay` instead.
    case other(currentDay: Int)

    var isStart: Bool {
        switch self {
        case .automaticStart, .pinnedStart: return true
        default: return false
        }
    }
}

// MARK: - Salary Main View

struct SalaryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \SalarySchedule.createdAt) private var schedules: [SalarySchedule]
    @Query(sort: \BankCard.sortOrder) private var cards: [BankCard]
    @State private var vm = SalaryViewModel()
    @State private var appeared = false
    @State private var actionsFor: SalarySchedule? = nil
    @State private var deleteFor: SalarySchedule? = nil

    /// The schedule the rest of the app runs its pay cycle on — pinned, or the
    /// largest active salary on the main card. The hero follows the same rule,
    /// so the date it shows is the date Home and the budget roll over on.
    private var anchor: SalarySchedule? { MainCard.anchorSalary(schedules) }

    private func cycleRole(for schedule: SalarySchedule) -> SalaryCycleRole {
        let candidates = MainCard.salaries(schedules)
        guard Set(candidates.map(\.dayOfMonth)).count > 1,
              candidates.contains(where: { $0.id == schedule.id }) else { return .none }
        if schedule.id == anchor?.id { return schedule.isPinned ? .pinnedStart : .automaticStart }
        return .other(currentDay: anchor?.dayOfMonth ?? schedule.dayOfMonth)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 18) {
                        header
                            .padding(.horizontal, 22)
                            .padding(.top, 20)

                        if schedules.isEmpty {
                            SalaryEmptyState(vm: vm, hasCards: !cards.isEmpty)
                                .padding(.top, 40)
                        } else {
                            if let anchor {
                                PaydayHeroCard(schedule: anchor)
                                    .padding(.horizontal, 22)
                            }
                            ForEach(schedules) { schedule in
                                SalaryCard(schedule: schedule,
                                           card: cards.first { $0.id == schedule.cardID },
                                           cycleRole: cycleRole(for: schedule),
                                           onMore: { HapticManager.shared.tap(); actionsFor = schedule })
                                    .padding(.horizontal, 22)
                            }
                        }
                        Spacer(minLength: 100)
                    }
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 16)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .onAppear {
                withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) { appeared = true }
            }
            .sheet(isPresented: $vm.showAddSheet, onDismiss: { vm.resetForm() }) {
                SalaryFormSheet(vm: vm, context: context)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(AppTheme.bg)
                    .preferredColorScheme(appColorScheme())
            }
            .sheet(item: $actionsFor) { schedule in
                SalaryActionsSheet(
                    schedule: schedule,
                    cycleRole: cycleRole(for: schedule),
                    onEdit: {
                        actionsFor = nil
                        // iOS drops a sheet presented while another is still
                        // animating away, so wait for the actions sheet to leave.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                            vm.loadForEdit(schedule, cards: cards)
                        }
                    },
                    onTogglePin: {
                        if !schedule.isPinned {
                            for s in schedules where s.id != schedule.id { s.isPinned = false }
                        }
                        schedule.isPinned.toggle()
                        try? context.save()
                        HapticManager.shared.success()
                    },
                    onToggleActive: {
                        schedule.isActive.toggle()
                        try? context.save()
                        HapticManager.shared.tap()
                    },
                    onDelete: {
                        actionsFor = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { deleteFor = schedule }
                    })
                .preferredColorScheme(appColorScheme())
            }
            .sheet(item: $deleteFor) { schedule in
                SalaryDeleteSheet(
                    schedule: schedule,
                    isAnchor: schedule.id == anchor?.id,
                    hasOtherActive: schedules.contains { $0.id != schedule.id && $0.isActive },
                    onConfirm: {
                        deleteFor = nil
                        // Delete after the sheet has gone. Deleting first leaves a
                        // closing sheet re-rendering a model whose backing data is
                        // already detached, which SwiftData traps on.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            context.delete(schedule)
                            try? context.save()
                            HapticManager.shared.success()
                        }
                    },
                    onCancel: { deleteFor = nil })
                .preferredColorScheme(appColorScheme())
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text(loc("salary.title"))
                    .font(.system(.title, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(loc("salary.smart_sub"))
                    .font(.system(.footnote))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            Spacer()
            if !schedules.isEmpty {
                Button {
                    HapticManager.shared.tap()
                    vm.resetForm()
                    vm.showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(.body, weight: .bold))
                        .foregroundStyle(cards.isEmpty ? AppTheme.textSecondary : AppTheme.onVividFill)
                        .frame(width: 44, height: 44)
                        .background(cards.isEmpty ? AppTheme.cardMid : AppTheme.accentFill, in: Circle())
                }
.accessibilityLabel(loc("salary.add_full"))
                .disabled(cards.isEmpty)
                .buttonStyle(ScaleButtonStyle())
            }
        }
    }
}

// MARK: - Payday Hero

/// The one question this screen is opened for — how long until I am paid, and
/// how far through this month's money am I — answered before anything else.
struct PaydayHeroCard: View {
    let schedule: SalarySchedule

    var body: some View {
        let cycle = SalaryCycle(dayOfMonth: schedule.dayOfMonth)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Circle().fill(AppTheme.accentFill).frame(width: 8, height: 8)
                Text(loc("salary.next_payday"))
                    .font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)
                Spacer()
                Text(schedule.label)
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(AppTheme.cardDark.opacity(0.8), in: Capsule())
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(cycle.countdown)
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(cycle.daysLeft == 0 ? AppTheme.accent : AppTheme.textPrimary)
                    .contentTransition(.numericText())
                Text(SalaryFormat.date(cycle.next, "EEEE d MMMM") + "  ·  "
                     + CurrencyManager.shared.formatted(schedule.amount, currency: schedule.currency))
                    .font(.system(.subheadline, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            PayCycleBar(cycle: cycle)
        }
        .padding(18)
        .background(
            LinearGradient(colors: [AppTheme.accent.opacity(0.20), AppTheme.cardDark],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: AppRadius.xl))
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.xl))
    }
}

// MARK: - Empty State

struct SalaryEmptyState: View {
    @Bindable var vm: SalaryViewModel
    var hasCards: Bool = true

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle().fill(AppTheme.accent.opacity(0.14)).frame(width: 120, height: 120)
                Circle().fill(AppTheme.accentFill).frame(width: 76, height: 76)
                Image(systemName: "banknote.fill")
                    .font(.system(.title, weight: .semibold))
                    .foregroundStyle(AppTheme.onVividFill)
            }
            VStack(spacing: 8) {
                Text(loc("salary.no_salary"))
                    .font(.system(.title3, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(loc("salary.nil"))
                    .font(.system(.subheadline))
                    .foregroundStyle(AppTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }
            if !hasCards {
                InlineBanner(tone: .warning, message: loc("home.add_card_salary"))
            }
            Button {
                HapticManager.shared.tap()
                vm.resetForm()
                vm.showAddSheet = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill").font(.system(.body))
                    Text(loc("salary.add_full")).font(.system(.callout, weight: .bold))
                }
                .foregroundStyle(hasCards ? AppTheme.onVividFill : AppTheme.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(hasCards ? AppTheme.accentFill : AppTheme.cardMid,
                            in: RoundedRectangle(cornerRadius: AppRadius.lg))
            }
            .buttonStyle(ScaleButtonStyle())
            .disabled(!hasCards)
        }
        .padding(.horizontal, 32)
    }
}

// MARK: - Salary Card

struct SalaryCard: View {
    let schedule: SalarySchedule
    let card: BankCard?
    let cycleRole: SalaryCycleRole
    let onMore: () -> Void

    /// This month's payday has passed AND the engine recorded it. A new
    /// schedule marks the current month as done so it never back-posts, which
    /// is why "passed" is part of the test: without it every freshly added
    /// salary would claim to have been paid already.
    private var recordedThisMonth: Bool {
        let cal = Calendar.current
        let now = Date()
        let m = cal.component(.month, from: now), y = cal.component(.year, from: now)
        let thisMonthPay = SalaryDateEngine.actualPayDate(dayOfMonth: schedule.dayOfMonth, month: m, year: y)
        return schedule.autoRecord
            && schedule.lastCreditedMonth == m && schedule.lastCreditedYear == y
            && cal.startOfDay(for: thisMonthPay) <= cal.startOfDay(for: now)
    }

    var body: some View {
        let cycle = SalaryCycle(dayOfMonth: schedule.dayOfMonth)
        let active = schedule.isActive
        VStack(alignment: .leading, spacing: 16) {
            // Identity + actions
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(active ? AppTheme.accentFill : AppTheme.cardMid)
                        .frame(width: 44, height: 44)
                    Image(systemName: "banknote.fill")
                        .font(.system(.body, weight: .semibold))
                        .foregroundStyle(active ? AppTheme.onVividFill : AppTheme.textSecondary)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(schedule.label)
                        .font(.system(.body, weight: .bold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(1)
                    // One line when it fits; otherwise the chips drop below the
                    // payday instead of squeezing it — "Cycle start" was being
                    // broken across two lines inside its own capsule.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) { paydayText; chips }
                        VStack(alignment: .leading, spacing: 6) {
                            paydayText
                            HStack(spacing: 6) { chips }
                        }
                    }
                }
                Spacer(minLength: 4)
                Button(action: onMore) {
                    Image(systemName: "ellipsis")
                        .font(.system(.callout, weight: .bold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .frame(width: 38, height: 38)
                        .background(AppTheme.cardMid.opacity(0.7), in: Circle())
                        .contentShape(Circle())
                }
.accessibilityLabel(loc("a11y.more_actions"))
.hitTarget(38)
                .buttonStyle(ScaleButtonStyle())
            }

            // Amount + countdown
            HStack(alignment: .firstTextBaseline) {
                Text(CurrencyManager.shared.formatted(schedule.amount, currency: schedule.currency))
                    .font(.system(.title, weight: .bold))
                    .foregroundStyle(active ? AppTheme.textPrimary : AppTheme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .contentTransition(.numericText())
                Spacer(minLength: 8)
                if active {
                    Text(cycle.countdown)
                        .font(.system(.footnote, weight: .bold))
                        .foregroundStyle(cycle.daysLeft == 0 ? AppTheme.onVividFill : cycle.tint)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(cycle.daysLeft == 0 ? AppTheme.accentFill
                                    : (cycle.daysLeft <= 3 ? AppTheme.orange.opacity(0.14) : AppTheme.cardMid.opacity(0.7)),
                                    in: Capsule())
                }
            }

            if active {
                PayCycleBar(cycle: cycle)
            }

            if recordedThisMonth {
                // Green on the glyph only — the words stay in textPrimary, where
                // the accent as 12pt text would be 2.56:1 on a white card.
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(.footnote))
                        .foregroundStyle(AppTheme.accent)
                    Text(loc("salary.recorded_this_month"))
                        .font(.system(.caption, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                }
            }

            // The next four actual paydays
            HStack(spacing: 8) {
                ForEach(SalaryDateEngine.upcomingDates(dayOfMonth: schedule.dayOfMonth, count: 4), id: \.self) { d in
                    PaydayTile(date: d, intended: schedule.dayOfMonth)
                }
            }
            .opacity(active ? 1 : 0.55)

            // Where it lands + full schedule
            HStack(spacing: 10) {
                if let card {
                    LinearGradient(colors: [Color(hex: card.gradientStart), Color(hex: card.gradientEnd)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                        .frame(width: 28, height: 20)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                    Text(String(format: loc("salary.lands_on"),
                                "\(CardLabel.title(card)) \(CardLabel.subtitle(card))"))
                        .font(.system(.caption))
                        .foregroundStyle(AppTheme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                NavigationLink(destination: SalaryDetailView(schedule: schedule)) {
                    HStack(spacing: 3) {
                        Text(loc("salary.full_schedule"))
                            .font(.system(.caption, weight: .semibold))
                        Image(systemName: "chevron.right")
                            .font(.system(.caption2, weight: .bold)).imageScale(.small)
                    }
                    .foregroundStyle(AppTheme.textPrimary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(18)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.xl))
    }

    private var paydayText: some View {
        Text(String(format: loc("salary.every_day"), schedule.dayOfMonth))
            .font(.system(.caption))
            .foregroundStyle(AppTheme.textSecondary)
            .lineLimit(1)
            .fixedSize()
    }

    @ViewBuilder
    private var chips: some View {
        if !schedule.isActive {
            chip(loc("salary.paused"), icon: "pause.fill", tint: AppTheme.textSecondary)
        } else {
            chip(schedule.autoRecord ? loc("salary.auto_chip") : loc("salary.manual"),
                 icon: schedule.autoRecord ? "wand.and.stars" : "hand.raised.fill",
                 tint: schedule.autoRecord ? AppTheme.textPrimary : AppTheme.orange)
            if cycleRole.isStart {
                // Pin glyph only when the user pinned it; a calendar when it is
                // the cycle start simply by being the largest salary.
                chip(loc("salary.anchor_chip"),
                     icon: { if case .pinnedStart = cycleRole { return "pin.fill" } else { return "calendar" } }(),
                     tint: AppTheme.textPrimary)
            }
        }
    }

    private func chip(_ text: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(.caption2, weight: .bold)).imageScale(.small)
            Text(text).font(.system(.caption2, weight: .semibold))
        }
        .foregroundStyle(tint)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(AppTheme.cardMid.opacity(0.7), in: Capsule())
    }
}

// MARK: - Actions Sheet (⋯)

/// What the ⋯ button opens.
///
/// It replaces a system action sheet listing five bare verbs — "📌 Pin to
/// Home", "Pause", "Turn off auto-record" — none of which said what it would
/// do. "Pin" in particular was mislabelled: it does not put anything on Home,
/// it makes this salary's payday the day the pay cycle starts for Home, the
/// budget and statistics. Each row now says its consequence, and auto-record
/// is a switch that shows its current state instead of a verb that hides it.
struct SalaryActionsSheet: View {
    @Bindable var schedule: SalarySchedule
    let cycleRole: SalaryCycleRole
    let onEdit: () -> Void
    let onTogglePin: () -> Void
    let onToggleActive: () -> Void
    let onDelete: () -> Void

    @Environment(\.modelContext) private var context
    @State private var contentHeight: CGFloat = 480

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(schedule.isActive ? AppTheme.accentFill : AppTheme.cardMid)
                        .frame(width: 46, height: 46)
                    Image(systemName: "banknote.fill")
                        .font(.system(.title3, weight: .semibold))
                        .foregroundStyle(schedule.isActive ? AppTheme.onVividFill : AppTheme.textSecondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(schedule.label)
                        .font(.system(.body, weight: .bold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(1)
                    Text(CurrencyManager.shared.formatted(schedule.amount, currency: schedule.currency)
                         + "  ·  " + String(format: loc("salary.every_day"), schedule.dayOfMonth))
                        .font(.system(.footnote))
                        .foregroundStyle(AppTheme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 6)

            VStack(spacing: 0) {
                row(icon: "pencil", tint: AppTheme.blue,
                    title: loc("salary.action.edit"), detail: loc("salary.action.edit_sub"),
                    action: onEdit)
                divider
                switch cycleRole {
                case .none:
                    EmptyView()
                case .automaticStart:
                    row(icon: "pin.fill", tint: AppTheme.purple,
                        title: loc("salary.action.lock"), detail: loc("salary.action.lock_sub"),
                        action: onTogglePin)
                    divider
                case .pinnedStart:
                    row(icon: "pin.slash.fill", tint: AppTheme.purple,
                        title: loc("salary.action.unpin"), detail: loc("salary.action.unpin_sub"),
                        action: onTogglePin)
                    divider
                case .other(let currentDay):
                    row(icon: "pin.fill", tint: AppTheme.purple,
                        title: loc("salary.action.pin"),
                        detail: String(format: loc("salary.action.pin_sub_days"), schedule.dayOfMonth, currentDay),
                        action: onTogglePin)
                    divider
                }
                row(icon: schedule.isActive ? "pause.fill" : "play.fill", tint: AppTheme.orange,
                    title: loc(schedule.isActive ? "salary.pause" : "salary.resume"),
                    detail: loc(schedule.isActive ? "salary.action.pause_sub" : "salary.action.resume_sub"),
                    action: onToggleActive)
                divider
                HStack(spacing: 12) {
                    iconTile("wand.and.stars", tint: AppTheme.accentFill, solid: true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(loc("salary.autorecord_label"))
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundStyle(AppTheme.textPrimary)
                        Text(loc("salary.autorecord_hint"))
                            .font(.system(.caption))
                            .foregroundStyle(AppTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 6)
                    Toggle("", isOn: $schedule.autoRecord)
                        .labelsHidden()
                        .tint(AppTheme.accentFill)
                        .onChange(of: schedule.autoRecord) { _, _ in
                            try? context.save()
                            HapticManager.shared.tap()
                        }
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
            }
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))

            Button(action: onDelete) {
                HStack(spacing: 12) {
                    iconTile("trash.fill", tint: AppTheme.flowOut, solid: true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(loc("salary.action.delete"))
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundStyle(AppTheme.flowOut)
                        Text(loc("salary.delete_keeps"))
                            .font(.system(.caption))
                            .foregroundStyle(AppTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
            }
            .buttonStyle(ScaleButtonStyle())
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 + 24 }
        .presentationDetents([.height(contentHeight)])
        .presentationDragIndicator(.visible)
        .presentationBackground(AppTheme.bg)
        .presentationCornerRadius(28)
    }

    private var divider: some View {
        Rectangle().fill(AppTheme.cardMid.opacity(0.7)).frame(height: 1).padding(.leading, 62)
    }

    /// Green and red — the two colours that carry money in and money out — go
    /// SOLID with an `onVividFill` glyph, like every other green and red badge
    /// in the app; the rest sit as glyphs on their own pale tint.
    private func iconTile(_ icon: String, tint: Color, solid: Bool = false) -> some View {
        Image(systemName: icon)
            .font(.system(.subheadline, weight: .semibold))
            .foregroundStyle(solid ? AppTheme.onVividFill : tint)
            .frame(width: 36, height: 36)
            .background(solid ? tint : tint.opacity(0.14), in: RoundedRectangle(cornerRadius: AppRadius.sm))
    }

    private func row(icon: String, tint: Color, title: String, detail: String,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                iconTile(icon, tint: tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(detail)
                        .font(.system(.caption))
                        .foregroundStyle(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Delete Sheet

/// Says what deleting a salary schedule does and does NOT do. The old dialog
/// said "remove permanently", which reads as if recorded salary would vanish
/// too — it does not — and said nothing about the pay cycle moving, which it
/// does when this is the schedule the cycle runs on.
struct SalaryDeleteSheet: View {
    let schedule: SalarySchedule
    let isAnchor: Bool
    let hasOtherActive: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void
    @State private var contentHeight: CGFloat = 380

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().fill(AppTheme.flowOut).frame(width: 56, height: 56)
                Image(systemName: "trash.fill")
                    .font(.system(.title2, weight: .semibold))
                    .foregroundStyle(AppTheme.onVividFill)
            }
            .padding(.top, 8)

            Text(String(format: loc("salary.delete_title"), schedule.label))
                .font(.system(.title3, weight: .bold))
                .foregroundStyle(AppTheme.textPrimary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 10) {
                note("checkmark.circle.fill", AppTheme.accent, loc("salary.delete_keeps"))
                if isAnchor && schedule.isActive {
                    note("arrow.triangle.2.circlepath", AppTheme.orange,
                         loc(hasOtherActive ? "salary.delete_anchor_other" : "salary.delete_anchor_month"))
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))

            VStack(spacing: 10) {
                Button(action: onConfirm) {
                    Text(loc("common.delete"))
                        .font(.system(.callout, weight: .bold))
                        .foregroundStyle(AppTheme.onVividFill)
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                        .background(AppTheme.flowOut, in: RoundedRectangle(cornerRadius: AppRadius.lg))
                }
                .buttonStyle(ScaleButtonStyle())
                Button {
                    HapticManager.shared.tap(); onCancel()
                } label: {
                    Text(loc("tx.delete_keep"))
                        .font(.system(.callout, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
                }
                .buttonStyle(ScaleButtonStyle())
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 + 24 }
        .presentationDetents([.height(contentHeight)])
        .presentationDragIndicator(.visible)
        .presentationBackground(AppTheme.bg)
        .presentationCornerRadius(28)
        .onAppear { HapticManager.shared.warning() }
    }

    private func note(_ icon: String, _ tint: Color, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.system(.subheadline)).foregroundStyle(tint)
            Text(text)
                .font(.system(.footnote))
                .foregroundStyle(AppTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Payday Grid

/// The month laid out as the 31 days it can be. Picking day 25 on the old
/// stepper was 24 taps of "+"; this is one.
struct PaydayGrid: View {
    @Binding var day: Int
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(1...31, id: \.self) { d in
                let on = d == day
                Button {
                    HapticManager.shared.select()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { day = d }
                } label: {
                    Text("\(d)")
                        .font(.system(size: 15, weight: on ? .bold : .medium))
                        .foregroundStyle(on ? AppTheme.onVividFill : AppTheme.textPrimary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background(on ? AppTheme.accentFill : Color.clear, in: Circle())
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
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
        return SalaryDateEngine.actualPayDate(dayOfMonth: vm.formDay,
                                              month: cal.component(.month, from: .now),
                                              year: cal.component(.year, from: .now))
    }
    private var previewAdjusted: Bool {
        SalaryDateEngine.wasAdjusted(intended: vm.formDay, actual: previewDate)
    }
    private var lockedCard: BankCard? { cards.first { $0.id == vm.formCardID } }
    private var cardIndex: Binding<Int> {
        Binding(get: { cards.firstIndex { $0.id == vm.formCardID } ?? 0 },
                set: { i in if cards.indices.contains(i) { vm.formCardID = cards[i].id } })
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 22) {
                        amountSection
                        IconField(label: loc("salary.label"),
                                  icon: "briefcase.fill",
                                  placeholder: loc("salary.label_placeholder"),
                                  text: $vm.formLabel)
                            .padding(.horizontal, 22)
                        paydaySection
                        cardSection
                        autoRecordSection
                        if !isEditing {
                            InlineBanner(tone: .info,
                                         message: loc("salary.auto_note") + "\n" + loc("salary.auto_note_sub"))
                                .padding(.horizontal, 22)
                        }
                        if let err = vm.formError {
                            InlineBanner(tone: .error, message: err)
                                .padding(.horizontal, 22)
                                .transition(.opacity)
                        }
                        saveButton
                        Spacer(minLength: 30)
                    }
                    .padding(.top, 8)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 16)
                    .animation(AppMotion.appear, value: appeared)
                }
            }
            .navigationTitle(isEditing ? loc("salary.edit") : loc("salary.new"))
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
            // The pager always shows a card, so something must be selected to
            // match it — otherwise the form showed a card and then refused to
            // save because "no card was chosen".
            if vm.formCardID == nil, let first = cards.first { vm.formCardID = first.id }
            if let card = lockedCard { vm.formCurrency = card.currency }
            withAnimation { appeared = true }
        }
        .onChange(of: vm.formCardID) { _, newID in
            if let id = newID, let card = cards.first(where: { $0.id == id }) {
                vm.formCurrency = card.currency
            }
        }
    }

    private var amountSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                // Locked to the receiving card's currency: salary is recorded
                // on that card, so any other currency would be converted anyway.
                HStack(spacing: 6) {
                    Text(CurrencyManager.symbol(for: vm.formCurrency))
                        .font(.system(.subheadline, weight: .bold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(vm.formCurrency)
                        .font(.system(.footnote, weight: .medium))
                        .foregroundStyle(AppTheme.textSecondary)
                    if lockedCard != nil {
                        Image(systemName: "lock.fill").font(.system(.caption2)).imageScale(.small)
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                }
                .padding(.horizontal, 13).padding(.vertical, 12)
                .background(AppTheme.cardMid, in: RoundedRectangle(cornerRadius: AppRadius.md))

                TextField("0", text: $vm.formAmount)
                    .font(.system(.largeTitle, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .keyboardType(.decimalPad)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))

            if let p = AmountInputHelper.preview(vm.formAmount, currency: vm.formCurrency) {
                Text(p)
                    .font(.system(.caption, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
        .padding(.horizontal, 22)
    }

    private var paydaySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            FormSectionLabel(text: loc("salary.payday"))
            VStack(spacing: 12) {
                PaydayGrid(day: $vm.formDay)

                Rectangle().fill(AppTheme.cardMid.opacity(0.7)).frame(height: 1)

                // What that choice means THIS month, live.
                HStack(spacing: 12) {
                    Image(systemName: previewAdjusted ? "arrow.uturn.backward" : "checkmark")
                        .font(.system(.subheadline, weight: .bold))
                        .foregroundStyle(AppTheme.onVividFill)
                        .frame(width: 32, height: 32)
                        .background(previewAdjusted ? AppTheme.orange : AppTheme.accentFill, in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(format: loc("salary.this_month_on"),
                                    SalaryFormat.date(previewDate, "EEEE d MMM")))
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundStyle(AppTheme.textPrimary)
                        Text(previewAdjusted
                             ? String(format: loc("salary.moved"), vm.formDay)
                             : loc("salary.on_business_day"))
                            .font(.system(.caption))
                            .foregroundStyle(previewAdjusted ? AppTheme.orange : AppTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .animation(.spring(response: 0.3), value: vm.formDay)

                if vm.formDay >= 29 {
                    Label(loc("salary.short_month_hint"), systemImage: "info.circle")
                        .font(.system(.caption2))
                        .foregroundStyle(AppTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(14)
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
        }
        .padding(.horizontal, 22)
    }

    @ViewBuilder
    private var cardSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            FormSectionLabel(text: loc("salary.deposit_to"))
                .padding(.horizontal, 22)
            if cards.isEmpty {
                InlineBanner(tone: .warning, message: loc("home.add_card_salary"))
                    .padding(.horizontal, 22)
            } else {
                CardSwipePicker(cards: cards, selectedIndex: cardIndex) { card in
                    (loc("home.balance_total"), card.formattedBalance)
                }
                // Someone with two jobs paid into two accounts is exactly who
                // hits this. Said while the choice is open, rather than
                // discovered later as a budget that ignores this income.
                if let id = vm.formCardID, MainCard.id != nil, id.uuidString != MainCard.id {
                    Label(loc("salary.not_main_card"), systemImage: "info.circle")
                        .font(.system(.caption2))
                        .foregroundStyle(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 22)
                }
            }
        }
    }

    private var autoRecordSection: some View {
        HStack(spacing: 12) {
            Image(systemName: "wand.and.stars")
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(AppTheme.onVividFill)
                .frame(width: 36, height: 36)
                .background(AppTheme.accentFill, in: RoundedRectangle(cornerRadius: AppRadius.sm))
            VStack(alignment: .leading, spacing: 2) {
                Text(loc("salary.autorecord_label"))
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(loc("salary.autorecord_hint"))
                    .font(.system(.caption))
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Toggle("", isOn: $vm.formAutoRecord)
                .labelsHidden()
                .tint(AppTheme.accentFill)
        }
        .padding(14)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
        .padding(.horizontal, 22)
    }

    private var saveButton: some View {
        Button { save() } label: {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").font(.system(.body))
                Text(isEditing ? loc("common.save") : loc("salary.add_full"))
                    .font(.system(.callout, weight: .bold))
            }
            .foregroundStyle(cards.isEmpty ? AppTheme.textSecondary : AppTheme.onVividFill)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 17)
            .background(cards.isEmpty ? AppTheme.textSecondary.opacity(0.25) : AppTheme.accentFill,
                        in: RoundedRectangle(cornerRadius: AppRadius.lg))
        }
        .buttonStyle(ScaleButtonStyle())
        .disabled(cards.isEmpty)
        .padding(.horizontal, 22)
        .padding(.top, 4)
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
            existing.autoRecord = vm.formAutoRecord
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
            schedule.autoRecord = vm.formAutoRecord
            // Skip the current month — user should add this month's income manually
            schedule.lastCreditedMonth = cal.component(.month, from: now)
            schedule.lastCreditedYear  = cal.component(.year, from: now)
            context.insert(schedule)
        }
        try? context.save()
        HapticManager.shared.success()

        // Schedule 3-day and 1-day advance device + in-app notifications
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
    /// Section heading. Defaults to the salary "Credit to" copy; the recurring
    /// expenses form overrides it with a "Charge to" key.
    var titleKey: String = "salary.credit_to"
    @Query(sort: \BankCard.sortOrder) private var cards: [BankCard]

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(loc(titleKey))
                    .font(.system(.footnote))
                    .foregroundStyle(AppTheme.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 22)

            if cards.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "creditcard.trianglebadge.exclamationmark")
                        .font(.system(.subheadline)).foregroundStyle(AppTheme.orange)
                    Text(loc("home.add_card_salary"))
                        .font(.system(.footnote)).foregroundStyle(AppTheme.textSecondary)
                }
                .padding(14)
                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
                .padding(.horizontal, 22)
            } else {
                CardChipPicker(cards: cards,
                               isSelected: { $0.id == selectedCardID },
                               onSelect: { selectedCardID = $0.id })
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
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

    var body: some View {
        let cycle = SalaryCycle(dayOfMonth: schedule.dayOfMonth)
        let dates = SalaryDateEngine.upcomingDates(dayOfMonth: schedule.dayOfMonth, count: 12)
        ZStack {
            AppTheme.bg.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    // Hero
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 12) {
                            ZStack {
                                Circle().fill(schedule.isActive ? AppTheme.accentFill : AppTheme.cardMid)
                                    .frame(width: 48, height: 48)
                                Image(systemName: "banknote.fill")
                                    .font(.system(.title3, weight: .semibold))
                                    .foregroundStyle(schedule.isActive ? AppTheme.onVividFill : AppTheme.textSecondary)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(CurrencyManager.shared.formatted(schedule.amount, currency: schedule.currency))
                                    .font(.system(.title, weight: .bold))
                                    .foregroundStyle(AppTheme.textPrimary)
                                    .lineLimit(1).minimumScaleFactor(0.7)
                                Text(String(format: loc("salary.every_day"), schedule.dayOfMonth)
                                     + (schedule.isActive ? "" : "  ·  " + loc("salary.paused")))
                                    .font(.system(.footnote))
                                    .foregroundStyle(AppTheme.textSecondary)
                            }
                            Spacer(minLength: 0)
                        }
                        if schedule.isActive {
                            HStack(alignment: .firstTextBaseline) {
                                Text(loc("salary.next_payday"))
                                    .font(.system(.footnote, weight: .semibold))
                                    .foregroundStyle(AppTheme.textSecondary)
                                Spacer()
                                Text(cycle.countdown)
                                    .font(.system(.title3, weight: .bold))
                                    .foregroundStyle(cycle.daysLeft == 0 ? AppTheme.accent : cycle.tint)
                            }
                            PayCycleBar(cycle: cycle)
                        }
                    }
                    .padding(18)
                    .background(
                        LinearGradient(colors: [AppTheme.accent.opacity(0.20), AppTheme.cardDark],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: AppRadius.xl))
                    .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.xl))
                    .padding(.horizontal, 22)

                    if let card = linkedCard {
                        VStack(alignment: .leading, spacing: 10) {
                            FormSectionLabel(text: loc("salary.credited_to"))
                                .padding(.horizontal, 22)
                            CardFaceView(card: card, label: loc("home.balance_total"), value: card.formattedBalance)
                                .frame(height: 100)
                                .padding(.horizontal, 22)
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        FormSectionLabel(text: loc("salary.upcoming_12"))
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(dates, id: \.self) { d in
                                PaydayTile(date: d, intended: schedule.dayOfMonth)
                            }
                        }
                        HStack(spacing: 6) {
                            Circle().fill(AppTheme.orange).frame(width: 7, height: 7)
                            Text(loc("salary.adjusted_legend"))
                                .font(.system(.caption2))
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                    }
                    .padding(16)
                    .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.xl))
                    .padding(.horizontal, 22)

                    Spacer(minLength: 40)
                }
                .padding(.top, 12)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 16)
            }
        }
        .navigationTitle(schedule.label)
        .navigationBarTitleDisplayMode(.large)
        // The list hides its bar for the custom header; this screen needs one
        // for its title and the way back.
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(AppTheme.bg, for: .navigationBar)
        .onAppear { withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) { appeared = true } }
    }
}
