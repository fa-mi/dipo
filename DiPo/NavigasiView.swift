import SwiftUI
import SwiftData

// MARK: - DiPo Navigasi: the screens
//
// One screen in three states: where to (no trip yet), which way (the routes to
// one goal), and the guidance once a route is chosen. Pushed from Plan —
// DiPo's reminder on Home opens it there — or a sheet from a goal's screen.
// The engine and its rules are in Navigasi.swift.

struct NavigasiView: View {
    /// The goal to plan a route to, when opened from that goal's screen.
    var goal: SavingsGoal? = nil
    /// Opened as a sheet: it carries its own Done.
    var inSheet = false

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \SavingsGoal.createdAt) private var goals: [SavingsGoal]
    @Query(sort: \BankCard.sortOrder) private var cards: [BankCard]
    @Query(sort: \SalarySchedule.createdAt) private var salaries: [SalarySchedule]
    @Query private var bills: [RecurringExpense]
    @AppStorage(Navigasi.tripKey) private var tripData = Data()

    /// The goal whose routes are on screen; nil shows the trip, or where to.
    @State private var planning: SavingsGoal?
    @State private var opened = false
    @State private var makingGoal = false

    private var trip: Navigasi.Trip? { Navigasi.Trip.decode(tripData) }
    private var tripGoal: SavingsGoal? {
        guard let trip else { return nil }
        return goals.first { $0.id == trip.goalID }
    }
    /// The trip's goal when its monthly plan was cleared on the goal's own
    /// screen: there is no route left to follow, so it asks for one again.
    private var reroute: SavingsGoal? {
        guard let goal = tripGoal, !goal.isCompleted, goal.monthlyContribution <= 0 else { return nil }
        return goal
    }

    var body: some View {
        ZStack {
            AppTheme.bg.ignoresSafeArea()
            content
        }
        .navigationTitle(loc("navi.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(AppTheme.bg, for: .navigationBar)
        .toolbar {
            if inSheet {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        HapticManager.shared.tap()
                        dismiss()
                    } label: {
                        Text(loc("common.done"))
                            .font(.system(.callout, weight: .semibold))
                            .foregroundStyle(AppTheme.accent)
                    }
                }
            }
        }
        .onAppear(perform: open)
        .sheet(isPresented: $makingGoal) {
            GoalFormSheet(editGoal: nil)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
        }
    }

    @ViewBuilder private var content: some View {
        if let goal = planning ?? reroute {
            planner(for: goal)
        } else if let trip, let tripGoal {
            guidance(trip: trip, goal: tripGoal)
        } else {
            destinations
        }
    }

    private func planner(for goal: SavingsGoal) -> some View {
        let replacing: SavingsGoal? = tripGoal?.id == goal.id ? nil : tripGoal
        let cancel: (() -> Void)? = tripGoal == nil || reroute != nil ? nil : { backToTrip() }
        return NaviRoutePlanner(goal: goal, replacing: replacing, cards: cards, salaries: salaries,
                                onCancel: cancel, onStart: { start($0, to: goal) })
            // A fresh planner per goal: what it read is that goal's.
            .id(goal.id)
    }

    private func guidance(trip: Navigasi.Trip, goal: SavingsGoal) -> some View {
        NaviGuidance(goal: goal, trip: trip, cards: cards, salaries: salaries, bills: bills,
                     onAccept: { accept($0) }, onEnd: { end() },
                     onChangeRoute: { withAnimation { planning = goal } })
    }

    private var destinations: some View {
        NaviDestinations(goals: goals.filter { !$0.isCompleted },
                         onPick: { picked in withAnimation { planning = picked } },
                         onNewGoal: { makingGoal = true })
    }

    private func open() {
        guard !opened else { return }
        opened = true
        // A trip whose goal was deleted has nowhere left to go.
        if trip != nil && tripGoal == nil { tripData = Data() }
        if let goal, !goal.isCompleted, goal.id != trip?.goalID { planning = goal }
    }

    private func start(_ route: Navigasi.Route, to goal: SavingsGoal) {
        // The route's amount becomes the goal's own plan, so the goal, its card
        // and every estimate say the same as the trip.
        goal.monthlyContribution = route.monthly
        try? context.save()
        tripData = Navigasi.Trip(goalID: goal.id, toll: route.toll, startedAt: .now, acceptedCycle: nil).encoded
        HapticManager.shared.success()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { planning = nil }
    }

    private func backToTrip() {
        withAnimation { planning = nil }
    }

    private func accept(_ cycle: String) {
        guard var trip else { return }
        trip.acceptedCycle = cycle
        tripData = trip.encoded
        HapticManager.shared.select()
    }

    private func end() {
        tripData = Data()
        HapticManager.shared.tap()
    }
}

// MARK: - Where to

private struct NaviDestinations: View {
    let goals: [SavingsGoal]
    let onPick: (SavingsGoal) -> Void
    let onNewGoal: () -> Void

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(loc("navi.where_to"))
                        .font(.system(.title2, weight: .bold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(loc(goals.isEmpty ? "navi.no_goals" : "navi.where_to_sub"))
                        .font(.system(.subheadline))
                        .foregroundStyle(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if goals.isEmpty {
                    Button {
                        HapticManager.shared.tap()
                        onNewGoal()
                    } label: {
                        Text(loc("navi.make_goal"))
                            .font(.system(.callout, weight: .bold))
                            .foregroundStyle(AppTheme.onVividFill)
                            .frame(maxWidth: .infinity).padding(.vertical, 15)
                            .background(AppTheme.accentFill, in: RoundedRectangle(cornerRadius: AppRadius.lg))
                    }
                    .buttonStyle(ScaleButtonStyle())
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(goals.enumerated()), id: \.element.id) { index, goal in
                            if index > 0 {
                                Rectangle().fill(AppTheme.cardMid.opacity(0.7)).frame(height: 1).padding(.leading, 68)
                            }
                            row(goal)
                        }
                    }
                    .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 16)
            .padding(.bottom, 40)
            .containerRelativeFrame(.horizontal)
        }
    }

    private func row(_ goal: SavingsGoal) -> some View {
        let cm = CurrencyManager.shared
        return Button {
            HapticManager.shared.tap()
            onPick(goal)
        } label: {
            HStack(spacing: 14) {
                Text(goal.emoji)
                    .font(.system(.title3))
                    .frame(width: 40, height: 40)
                    .background(AppTheme.cardMid, in: RoundedRectangle(cornerRadius: AppRadius.sm))
                VStack(alignment: .leading, spacing: 6) {
                    Text(goal.name)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(1)
                    Text(String(format: loc("navi.of_target"),
                                cm.formatted(goal.currentValue, currency: goal.currency),
                                cm.formatted(goal.targetAmount, currency: goal.currency)))
                        .font(.system(.caption))
                        .foregroundStyle(AppTheme.textSecondary)
                    SavingsProgressBar(progress: goal.progress, height: 5)
                }
                Image(systemName: "chevron.right")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Which way

private struct NaviRoutePlanner: View {
    let goal: SavingsGoal
    /// The goal of the trip this one would replace.
    let replacing: SavingsGoal?
    let cards: [BankCard]
    let salaries: [SalarySchedule]
    /// Back to the trip under way, when there is one.
    let onCancel: (() -> Void)?
    let onStart: (Navigasi.Route) -> Void

    /// Read from the whole ledger once, not on every tap or keystroke.
    private struct Inputs {
        let cycle: Navigasi.Cycle
        let setAside: Double
        let toll: Navigasi.Toll?
        /// The salary a month, in the goal's currency.
        let income: Double
    }

    @State private var inputs: Inputs?
    @State private var chosen: Navigasi.Route.Kind?
    @State private var customText = ""
    @State private var typing = false

    private func money(_ v: Double) -> String { CurrencyManager.shared.formatted(v, currency: goal.currency) }

    private var routes: [Navigasi.Route] {
        guard let inputs else { return [] }
        var all = Navigasi.routes(remaining: goal.remaining, plan: goal.monthlyContribution,
                                  targetDate: goal.targetDate, toll: inputs.toll, setAside: inputs.setAside,
                                  cycle: inputs.cycle, now: .now, currency: goal.currency)
        if let custom = Navigasi.custom(NumberInput.amount(customText), remaining: goal.remaining,
                                        setAside: inputs.setAside, cycle: inputs.cycle, now: .now),
           !all.contains(where: { $0.monthly == custom.monthly }) {
            all.append(custom)
        }
        return all
    }

    private var selected: Navigasi.Route? {
        let all = routes
        return all.first { $0.kind == chosen } ?? all.first
    }

    var body: some View {
        VStack(spacing: 0) {
            NaviRoad(progress: goal.progress,
                     marks: NaviRoad.marks(for: goal, monthly: selected?.monthly ?? 0,
                                           cycle: inputs?.cycle, setAside: inputs?.setAside ?? 0),
                     destination: "\(goal.emoji) \(goal.name)", here: loc("navi.here"))
                .frame(height: 236)
            panel
        }
        .onAppear { if inputs == nil { inputs = readInputs() } }
    }

    private func readInputs() -> Inputs {
        let cm = CurrencyManager.shared
        let tx = cards.flatMap(\.transactions)
        let cycle = MainCard.payDay(salaries).map {
            Navigasi.payCycle(payDay: $0, salaryDates: StatPeriod.salaryDates(on: MainCard.resolve(in: cards)))
        } ?? Navigasi.month(of: .now)
        let income = MainCard.salaries(salaries).reduce(0) { $0 + cm.convert($1.amount, from: $1.currency, to: goal.currency) }
        return Inputs(cycle: cycle,
                      setAside: Navigasi.setAside(to: goal, transactions: tx, since: cycle.start),
                      toll: Navigasi.toll(transactions: tx, currency: goal.currency, now: .now),
                      income: income)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(routes) { card($0) }
                    customRow
                    ForEach(noteLines, id: \.self) { line in
                        Text(line)
                            .font(.system(.caption))
                            .foregroundStyle(AppTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 2)
                }
                .padding(.top, 10).padding(.bottom, 14)
                .containerRelativeFrame(.horizontal)
            }
            startButton
        }
        .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 10)
        .background {
            UnevenRoundedRectangle(topLeadingRadius: AppRadius.xl, topTrailingRadius: AppRadius.xl)
                .fill(AppTheme.cardDark)
                .ignoresSafeArea(edges: .bottom)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(goal.emoji) \(goal.name)")
                    .font(.system(.headline, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let onCancel {
                    Button {
                        HapticManager.shared.tap()
                        onCancel()
                    } label: {
                        Text(loc("common.cancel"))
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundStyle(AppTheme.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
            Text(String(format: loc("navi.of_target"), money(goal.currentValue), money(goal.targetAmount))
                 + " · " + loc("navi.choose_route"))
                .font(.system(.footnote))
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    private func card(_ route: Navigasi.Route) -> some View {
        let all = routes
        let on = route.id == selected?.id
        let earliest = all.map(\.arrival).min() ?? route.arrival
        let later = Navigasi.monthsUntil(route.arrival, from: earliest)
        let tag = later > 0 ? "+" + Navigasi.duration(months: later) : (all.count > 1 ? loc("navi.fastest") : "")
        return Button {
            HapticManager.shared.select()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { chosen = route.kind }
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(Navigasi.monthYear(route.arrival))
                            .font(.system(.title3, weight: .heavy))
                            .foregroundStyle(AppTheme.textPrimary)
                        Text(tag)
                            .font(.system(.caption, weight: .bold))
                            .foregroundStyle(later == 0 ? AppTheme.accent : AppTheme.textSecondary)
                    }
                    Text(String(format: loc("navi.per_month"), money(route.monthly)) + " · " + kindLabel(route))
                        .font(.system(.footnote))
                        .foregroundStyle(AppTheme.textSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                ZStack {
                    Circle().stroke(AppTheme.textSecondary.opacity(on ? 0 : 0.6), lineWidth: 1.5)
                    if on {
                        Circle().fill(AppTheme.accentFill)
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(AppTheme.onVividFill)
                    }
                }
                .frame(width: 22, height: 22)
            }
            .padding(.horizontal, 13).padding(.vertical, 10)
            .background(on ? AppTheme.accent.opacity(0.09) : AppTheme.bg,
                        in: RoundedRectangle(cornerRadius: AppRadius.md))
            .overlay(RoundedRectangle(cornerRadius: AppRadius.md)
                .stroke(on ? AppTheme.accent : Color.clear, lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: AppRadius.md))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func kindLabel(_ route: Navigasi.Route) -> String {
        switch route.kind {
        case .plan:      return loc("navi.route.plan")
        case .onTime:    return loc("navi.route.on_time")
        case .suggested: return loc("navi.route.suggested")
        case .custom:    return loc("navi.route.custom")
        case .toll:
            guard let toll = route.toll, let category = toll.category else { return "" }
            return "\(category.displayLabel) −\(money(toll.cut))"
        }
    }

    @ViewBuilder private var customRow: some View {
        if typing {
            MoneyField(label: loc("navi.custom_label"), prefix: CurrencyManager.symbol(for: goal.currency),
                       bg: AppTheme.bg, text: $customText)
                .onChange(of: customText) { _, text in
                    // The typed amount, or the route that already has it.
                    let amount = NumberInput.amount(text)
                    if amount > 0, let match = routes.first(where: { $0.monthly == amount }) { chosen = match.kind }
                }
        } else {
            Button {
                HapticManager.shared.tap()
                withAnimation(.spring(response: 0.3)) { typing = true }
            } label: {
                HStack {
                    Text(loc("navi.route.custom"))
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(.caption, weight: .semibold))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .padding(.horizontal, 13).padding(.vertical, 13)
                .background(AppTheme.bg, in: RoundedRectangle(cornerRadius: AppRadius.md))
                .contentShape(RoundedRectangle(cornerRadius: AppRadius.md))
            }
            .buttonStyle(.plain)
        }
    }

    /// The share of the salary the chosen route takes, what the faster one
    /// costs and buys, and the trip it would replace.
    private var noteLines: [String] {
        var lines: [String] = []
        guard let inputs else { return lines }
        if goal.remaining < 1 { lines.append(loc("savings.reached")) }
        if let route = selected, inputs.income > 0 {
            lines.append(String(format: loc("savings.pct_of_income"),
                                String(format: "%.0f", route.monthly / inputs.income * 100)) + ".")
        }
        let all = routes
        if let toll = inputs.toll, let category = toll.category,
           let faster = all.first(where: { $0.kind == .toll }),
           let base = all.first(where: { $0.kind != .toll && abs($0.monthly + toll.cut - faster.monthly) < 0.5 }) {
            let sooner = Navigasi.monthsUntil(base.arrival, from: faster.arrival)
            if sooner > 0 {
                lines.append(String(format: loc("navi.toll_note"), category.displayLabel, money(toll.average),
                                    money(toll.cut), Navigasi.duration(months: sooner)))
            }
        }
        if let replacing {
            lines.append(String(format: loc("navi.replaces"), "\(replacing.emoji) \(replacing.name)"))
        }
        return lines
    }

    private var startButton: some View {
        let route = selected
        return Button {
            if let route { onStart(route) }
        } label: {
            Text(loc("navi.start"))
                .font(.system(.callout, weight: .bold))
                .foregroundStyle(AppTheme.onVividFill)
                .frame(maxWidth: .infinity).padding(.vertical, 15)
                .background(AppTheme.accentFill.opacity(route == nil ? 0.4 : 1),
                            in: RoundedRectangle(cornerRadius: AppRadius.lg))
        }
        .buttonStyle(ScaleButtonStyle())
        .disabled(route == nil)
    }
}

// MARK: - The guidance

private struct NaviGuidance: View {
    let goal: SavingsGoal
    let trip: Navigasi.Trip
    let cards: [BankCard]
    let salaries: [SalarySchedule]
    let bills: [RecurringExpense]
    let onAccept: (String) -> Void
    let onEnd: () -> Void
    let onChangeRoute: () -> Void

    @Environment(\.modelContext) private var context
    @State private var depositing = false
    @State private var depositAmount: Double = 0
    @State private var confirmingEnd = false
    @State private var voice = DiPoVoice()

    /// What the card at the top says.
    private struct Turn {
        let icon: String
        let tint: Color
        let headline: String
        let detail: String
        let footnote: String?
        /// Set aside this much now, from the card.
        var setAside: Double? = nil

        var spoken: String { [headline, detail, footnote].compactMap { $0 }.joined(separator: ". ") }
    }

    private var name: String { "\(goal.emoji) \(goal.name)" }
    private func money(_ v: Double) -> String { CurrencyManager.shared.formatted(v, currency: goal.currency) }

    var body: some View {
        let tx = cards.flatMap(\.transactions)
        let status = Navigasi.status(of: trip, goal: goal, transactions: tx,
                                     payDay: MainCard.payDay(salaries),
                                     salaryDates: StatPeriod.salaryDates(on: MainCard.resolve(in: cards)))
        let next = turn(for: status)
        ZStack {
            NaviRoad(progress: goal.progress,
                     marks: NaviRoad.marks(for: goal, monthly: goal.monthlyContribution,
                                           cycle: status.cycle, setAside: status.setAside),
                     offRoute: status.leg.isBehind,
                     insets: EdgeInsets(top: 170, leading: 0, bottom: 200, trailing: 0))
                .ignoresSafeArea(edges: .bottom)
            VStack(spacing: 10) {
                instruction(next)
                Spacer(minLength: 0)
                if let toll = trip.toll, let category = toll.category, status.leg != .arrived {
                    tollGauge(toll, category, status: status, transactions: tx)
                }
                bottom(status)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 10)
        }
        .sheet(isPresented: $depositing) {
            DepositSheet(goal: goal, initialAmount: depositAmount) { amount, card in
                depositing = false
                if goal.recordDeposit(amount, from: card, context: context) {
                    HapticManager.shared.rigidImpact()
                    goal.announceReached()
                } else {
                    HapticManager.shared.success()
                }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(AppTheme.bg)
        }
        .confirmSheet(isPresented: $confirmingEnd, icon: "flag.fill", tone: .warning,
                      title: String(format: loc("navi.end_title"), name),
                      message: loc("navi.end_msg"), confirmLabel: loc("navi.end"), onConfirm: onEnd)
        .onDisappear { voice.stop() }
    }

    // MARK: The next turn

    private func turn(for status: Navigasi.Status) -> Turn {
        let monthly = goal.monthlyContribution
        switch status.leg {
        case .arrived:
            return Turn(icon: "flag.checkered", tint: AppTheme.accent, headline: loc("navi.arrived"),
                        detail: String(format: loc("navi.arrived_sub"), name), footnote: nil)
        case .setAside(let due):
            return Turn(icon: "arrow.turn.up.right", tint: AppTheme.accent,
                        headline: String(format: loc("navi.set_aside"), money(due)),
                        detail: String(format: loc(status.cycle.fromPayday ? "navi.set_aside_payday"
                                                                           : "navi.set_aside_month"), name),
                        footnote: billLine("navi.bill_then", before: status.cycle.end),
                        setAside: due)
        case .behind(let short, let later):
            return Turn(icon: "arrow.uturn.backward", tint: AppTheme.orange, headline: loc("navi.off_route"),
                        detail: String(format: loc("navi.off_route_sub"), money(status.setAside), money(monthly)),
                        footnote: String(format: loc("navi.without"), Navigasi.monthYear(later)),
                        setAside: short)
        case .done, .accepted:
            let cal = Calendar.current
            let days = cal.dateComponents([.day], from: cal.startOfDay(for: .now),
                                          to: cal.startOfDay(for: status.cycle.end)).day ?? 0
            let amount = min(monthly, goal.remaining)
            let when = DateFormatterCache.template("dMMM").string(from: status.cycle.end)
            var footnote = billLine("navi.bill_before", before: status.cycle.end)
            if case .accepted(let later) = status.leg {
                footnote = String(format: loc("navi.new_route_taken"), Navigasi.monthYear(later))
            }
            return Turn(icon: "arrow.turn.up.right", tint: AppTheme.accent,
                        headline: days <= 1 ? loc("navi.tomorrow") : String(format: loc("navi.in_days"), days),
                        detail: String(format: loc(status.cycle.fromPayday ? "navi.next_payday" : "navi.next_month"),
                                       when, money(amount)),
                        footnote: footnote)
        }
    }

    /// The nearest bill still to pay before `end`: "Kos Rp 2.100.000 · Sab 1 Nov".
    private func billLine(_ key: String, before end: Date) -> String? {
        let due = bills.filter { $0.isActive && !$0.isChargedForCurrentDue }
            .map { ($0, RecurringDateEngine.nextDueDate(dayOfMonth: $0.dayOfMonth)) }
            .filter { $0.1 < end }
            .min { $0.1 < $1.1 }
        guard let due else { return nil }
        let (bill, date) = due
        return String(format: loc(key), bill.label,
                      CurrencyManager.shared.formatted(bill.amount, currency: bill.currency),
                      DateFormatterCache.template("EEEdMMM").string(from: date))
    }

    private func instruction(_ turn: Turn) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: turn.icon)
                    .font(.system(.title3, weight: .bold))
                    .foregroundStyle(turn.tint)
                    .frame(width: 44, height: 44)
                    .background(turn.tint.opacity(0.16), in: RoundedRectangle(cornerRadius: AppRadius.sm))
                VStack(alignment: .leading, spacing: 4) {
                    Text(turn.headline)
                        .font(.system(.title2, weight: .heavy))
                        .foregroundStyle(turn.tint == AppTheme.orange ? AppTheme.orange : AppTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(turn.detail)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Button {
                    HapticManager.shared.tap()
                    voice.speak(turn.spoken)
                } label: {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(.footnote, weight: .semibold))
                        .foregroundStyle(AppTheme.textSecondary)
                        .frame(width: 36, height: 36)
                        .background(AppTheme.cardMid, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(loc("navi.listen"))
            }
            if let amount = turn.setAside, turn.tint != AppTheme.orange {
                Button {
                    HapticManager.shared.tap()
                    depositAmount = amount
                    depositing = true
                } label: {
                    Text(loc("navi.set_aside_now"))
                        .font(.system(.subheadline, weight: .bold))
                        .foregroundStyle(AppTheme.onVividFill)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(AppTheme.accentFill, in: RoundedRectangle(cornerRadius: AppRadius.md))
                }
                .buttonStyle(ScaleButtonStyle())
                .padding(.top, 12)
            }
            if let footnote = turn.footnote {
                Rectangle().fill(AppTheme.cardMid).frame(height: 1).padding(.top, 12)
                Text(footnote)
                    .font(.system(.caption))
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 9)
            }
        }
        .padding(15)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.xl))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        .accessibilityElement(children: .combine)
    }

    // MARK: The toll

    private func tollGauge(_ toll: Navigasi.Toll, _ category: TxCategory, status: Navigasi.Status,
                           transactions: [TxRecord]) -> some View {
        let spent = Navigasi.spent(in: category, transactions: transactions, since: status.cycle.start,
                                   currency: goal.currency)
        let limit = toll.limit
        let over = spent > limit
        let share = limit > 0 ? min(spent / limit, 1) : 1
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(String(format: loc(status.cycle.fromPayday ? "navi.toll_payday" : "navi.toll_month"),
                            category.displayLabel))
                    .foregroundStyle(AppTheme.textSecondary)
                Spacer(minLength: 8)
                Text(String(format: loc("navi.toll_of"), money(spent), money(limit)))
                    .fontWeight(.semibold)
                    .foregroundStyle(over ? AppTheme.orange : AppTheme.textPrimary)
            }
            .font(.system(.caption))
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(AppTheme.cardMid)
                    Capsule().fill(over ? AppTheme.orange : AppTheme.accentFill)
                        .frame(width: max(g.size.width * share, 6))
                }
            }
            .frame(height: 7)
        }
        .padding(.horizontal, 15).padding(.vertical, 12)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.xl))
        .accessibilityElement(children: .combine)
    }

    // MARK: The bottom: arrival, the way back, or the finish

    @ViewBuilder private func bottom(_ status: Navigasi.Status) -> some View {
        switch status.leg {
        case .arrived:
            Button {
                HapticManager.shared.success()
                onEnd()
            } label: {
                Text(loc("navi.finish"))
                    .font(.system(.callout, weight: .bold))
                    .foregroundStyle(AppTheme.onVividFill)
                    .frame(maxWidth: .infinity).padding(.vertical, 15)
                    .background(AppTheme.accentFill, in: RoundedRectangle(cornerRadius: AppRadius.lg))
            }
            .buttonStyle(ScaleButtonStyle())
        case .behind(let short, let later):
            VStack(alignment: .leading, spacing: 9) {
                Text(loc("navi.which_way"))
                    .font(.system(.headline, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                Button {
                    HapticManager.shared.tap()
                    depositAmount = short
                    depositing = true
                } label: {
                    Text(String(format: loc("navi.back_on"), money(short)))
                        .font(.system(.subheadline, weight: .bold))
                        .foregroundStyle(AppTheme.onVividFill)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(AppTheme.accentFill, in: RoundedRectangle(cornerRadius: AppRadius.lg))
                }
                .buttonStyle(ScaleButtonStyle())
                Button {
                    onAccept(status.cycle.key)
                } label: {
                    Text(String(format: loc("navi.new_route"), Navigasi.monthYear(later)))
                        .font(.system(.subheadline, weight: .bold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity).padding(.vertical, 13)
                        .background(AppTheme.cardMid, in: RoundedRectangle(cornerRadius: AppRadius.lg))
                }
                .buttonStyle(ScaleButtonStyle())
            }
            .padding(15)
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.xl))
        case .setAside, .done, .accepted:
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(String(format: loc("navi.arrive"), status.arrival.map(Navigasi.monthYear) ?? "—"))
                        .font(.system(.title3, weight: .heavy))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(String(format: loc("navi.to_go"), money(goal.remaining),
                                Navigasi.duration(months: status.arrival.map { Navigasi.monthsUntil($0, from: .now) } ?? 0)))
                        .font(.system(.caption))
                        .foregroundStyle(AppTheme.textSecondary)
                    Button {
                        HapticManager.shared.tap()
                        onChangeRoute()
                    } label: {
                        Text(loc("navi.change_route"))
                            .font(.system(.caption, weight: .semibold))
                            .foregroundStyle(AppTheme.accent)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
                Spacer(minLength: 8)
                Button {
                    HapticManager.shared.tap()
                    confirmingEnd = true
                } label: {
                    Text(loc("navi.end"))
                        .font(.system(.subheadline, weight: .bold))
                        .foregroundStyle(AppTheme.onVividFill)
                        .padding(.horizontal, 18).padding(.vertical, 11)
                        .background(AppTheme.redFill, in: RoundedRectangle(cornerRadius: AppRadius.md))
                }
                .buttonStyle(ScaleButtonStyle())
            }
            .padding(15)
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.xl))
        }
    }
}

private extension Navigasi.Leg {
    var isBehind: Bool {
        if case .behind = self { return true }
        return false
    }
}

// MARK: - The road

/// The road from nothing saved to the goal, drawn as a map: the stretch
/// behind in green, the rest dotted, a dot for today and a mark at each
/// quarter. Decoration — everything on it is also said in words.
struct NaviRoad: View {
    struct Mark: Identifiable {
        let fraction: Double
        /// When the route passes it; nil once passed, or without a route.
        let label: String?
        var id: Double { fraction }
    }

    /// How far along, 0...1.
    let progress: Double
    var marks: [Mark] = []
    /// Beside the pin; empty draws the pin alone.
    var destination: String = ""
    /// Under today's dot; empty draws the dot alone.
    var here: String = ""
    var offRoute = false
    /// Room kept clear for cards over the map.
    var insets = EdgeInsets(top: 22, leading: 0, bottom: 34, trailing: 0)

    var body: some View {
        GeometryReader { g in
            let road = Curve(in: CGRect(x: insets.leading, y: insets.top,
                                        width: max(g.size.width - insets.leading - insets.trailing, 1),
                                        height: max(g.size.height - insets.top - insets.bottom, 1)))
            let path = road.path
            let done = min(max(progress, 0), 1)
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    var grid = Path()
                    for x in stride(from: 0, through: size.width, by: 26) {
                        grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height))
                    }
                    for y in stride(from: 0, through: size.height, by: 26) {
                        grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
                    }
                    ctx.stroke(grid, with: .color(AppTheme.cardMid.opacity(0.6)), lineWidth: 1)
                }
                path.stroke(AppTheme.cardMid, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                path.stroke((offRoute ? AppTheme.orange : AppTheme.accent).opacity(0.4),
                            style: StrokeStyle(lineWidth: 5, lineCap: .round, dash: [2, 9]))
                path.trimmedPath(from: 0, to: done)
                    .stroke(AppTheme.accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                ForEach(marks) { mark in
                    let at = road.point(atFraction: mark.fraction)
                    Circle()
                        .fill(AppTheme.bg)
                        .overlay(Circle().stroke(mark.fraction <= done ? AppTheme.accent : AppTheme.textSecondary,
                                                 lineWidth: 2.5))
                        .frame(width: 11, height: 11)
                        .position(at)
                    if let label = mark.label {
                        let right = at.x < g.size.width / 2
                        Color.clear.frame(width: 1, height: 1)
                            .overlay(alignment: right ? .leading : .trailing) {
                                Text(label)
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(AppTheme.textSecondary)
                                    .fixedSize()
                                    .offset(x: right ? 12 : -12)
                            }
                            .position(at)
                    }
                }
                Circle()
                    .fill(AppTheme.bg)
                    .overlay(Circle().stroke(AppTheme.accent, lineWidth: 3))
                    .frame(width: 14, height: 14)
                    .position(road.point(atFraction: 0))
                today(at: road.point(atFraction: done))
                pin(at: road.point(atFraction: 1))
            }
        }
        .accessibilityHidden(true)
    }

    private func today(at point: CGPoint) -> some View {
        ZStack {
            Circle().fill(AppTheme.blue.opacity(0.22)).frame(width: 28, height: 28)
            Circle().fill(AppTheme.blue).frame(width: 15, height: 15)
                .overlay(Circle().stroke(.white, lineWidth: 2.5))
        }
        .overlay(alignment: .top) {
            if !here.isEmpty {
                Text(here)
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .fixedSize()
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(AppTheme.bg.opacity(0.85), in: Capsule())
                    .offset(y: 28)
            }
        }
        .position(point)
    }

    private func pin(at point: CGPoint) -> some View {
        Image(systemName: "mappin.circle.fill")
            .font(.system(size: 26))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, AppTheme.red)
            .background(Circle().fill(AppTheme.bg).padding(3))
            .overlay(alignment: .trailing) {
                if !destination.isEmpty {
                    Text(destination)
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(1)
                        .fixedSize()
                        .offset(x: -24)
                }
            }
            .position(x: point.x, y: point.y - 4)
    }

    /// The quarter marks for a route at `monthly` a cycle, dated when the
    /// route reaches each one.
    static func marks(for goal: SavingsGoal, monthly: Double, cycle: Navigasi.Cycle?,
                      setAside: Double, now: Date = .now) -> [Mark] {
        [(0.25, "¼"), (0.5, "½"), (0.75, "¾")].map { fraction, glyph in
            let need = goal.targetAmount * fraction - goal.currentValue
            guard need >= 1, monthly > 0, let cycle,
                  let date = Navigasi.arrival(remaining: need, monthly: monthly,
                                              stillThisCycle: max(monthly - setAside, 0),
                                              cycle: cycle, now: now)
            else { return Mark(fraction: fraction, label: nil) }
            return Mark(fraction: fraction, label: "\(glyph) · \(Navigasi.monthYear(date))")
        }
    }

    /// One cubic S from the lower left to the upper right of `rect`, with
    /// points along it found by length, so marks sit where the trim ends.
    private struct Curve {
        let p0, c1, c2, p1: CGPoint
        private let samples: [CGPoint]
        private let lengths: [CGFloat]

        init(in rect: CGRect) {
            func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
            }
            p0 = at(0.14, 0.86); c1 = at(0.95, 0.92); c2 = at(0.05, 0.10); p1 = at(0.84, 0.16)
            var points: [CGPoint] = []
            var total: [CGFloat] = [0]
            let steps = 96
            for i in 0...steps {
                let t = CGFloat(i) / CGFloat(steps)
                let u = 1 - t
                let x = u * u * u * p0.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * p1.x
                let y = u * u * u * p0.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * p1.y
                let point = CGPoint(x: x, y: y)
                if let last = points.last {
                    total.append(total[total.count - 1] + hypot(point.x - last.x, point.y - last.y))
                }
                points.append(point)
            }
            samples = points
            lengths = total
        }

        var path: Path {
            Path { p in
                p.move(to: p0)
                p.addCurve(to: p1, control1: c1, control2: c2)
            }
        }

        func point(atFraction fraction: Double) -> CGPoint {
            guard let total = lengths.last, total > 0 else { return p0 }
            let target = total * CGFloat(min(max(fraction, 0), 1))
            guard let i = lengths.firstIndex(where: { $0 >= target }), i > 0 else { return samples[0] }
            let span = lengths[i] - lengths[i - 1]
            let k = span > 0 ? (target - lengths[i - 1]) / span : 0
            let a = samples[i - 1], b = samples[i]
            return CGPoint(x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k)
        }
    }
}
