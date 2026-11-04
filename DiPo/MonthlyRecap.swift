import SwiftUI

// MARK: - Monthly recap
//
// On the 1st, the month that just ended, told the way a passbook would: what
// went out, what came in, what is left, and where the money went, category by
// category.
//
// Every figure is one Statistics already defines, read the same way, so this
// screen and Statistics → Last month never disagree:
//
//   • money in is real income only (StatisticsView.income);
//   • spending is "spending & bills" — refunds taken off, transfers skipped,
//     and debt paid down and money put away kept apart (StatisticsView.living),
//     since neither buys anything new;
//   • the pot is the main card and its bill cards (MainCard), in the main
//     card's currency.
//
// The reminder used to bake numbers into the push when it was scheduled, which
// is whenever the app was last opened: a phone last opened on the 20th
// announced twenty days as "last month", and one opened on the 1st before
// 09:00 rescheduled it with the new month's zero. The push now says only that
// the summary is ready; the numbers are read when it is opened.

struct MonthlyRecap: Equatable {
    struct Row: Equatable, Identifiable {
        let category: TxCategory
        let amount: Double
        /// Spending rows behind `amount`.
        let count: Int
        /// Of all the spending shown, 0...1.
        let share: Double
        var id: String { category.rawValue }
    }

    /// First instant of the month.
    let month: Date
    let income: Double
    /// Spending & bills, as Statistics' headline counts it.
    let spent: Double
    /// Kept out of `spent`: paying down debt.
    let debtPaid: Double
    /// Kept out of `spent`: money put into savings and investments.
    let saved: Double
    /// Where `spent` went, largest first.
    let rows: [Row]

    /// Income less spending — the month's own result.
    var left: Double { income - spent }
    var txCount: Int { rows.reduce(0) { $0 + $1.count } }

    // MARK: Building

    /// The recap for the month that starts at `month`, or nil when nothing was
    /// recorded in it: no data is not a month of zeros.
    static func build(_ txs: [TxRecord], month: Date, cal: Calendar = .current,
                      convert: (TxRecord) -> Double) -> MonthlyRecap? {
        let start = monthStart(of: month, cal: cal)
        let end = cal.safeDate(byAdding: .month, value: 1, to: start)
        let slice = txs.filter { $0.date >= start && $0.date < end && $0.txSubtype != .transfer }

        let income = StatisticsView.income(slice, convert: convert)
        let spent = StatisticsView.living(slice, convert: convert)
        let debtPaid = PeriodCashBook.categorySpend(slice, .debtPayment, convert: convert)
        let saved = PeriodCashBook.categorySpend(slice, .investment, convert: convert)
        // A month whose refunds outweigh its spending still happened.
        guard slice.contains(where: { abs($0.amount) >= 0.5 }) else { return nil }

        // The same rows Statistics lists under "spending & bills".
        var totals: [TxCategory: Double] = [:]
        var counts: [TxCategory: Int] = [:]
        for tx in slice where tx.category != .debtPayment && tx.category != .investment {
            let amount = abs(convert(tx))
            if tx.txSubtype == .refund {
                totals[tx.category, default: 0] -= amount
            } else if tx.amount < 0 {
                totals[tx.category, default: 0] += amount
                counts[tx.category, default: 0] += 1
            }
        }
        let kept = totals.filter { $0.value >= 0.5 }
        let total = kept.values.reduce(0, +)
        let rows = kept
            .map { Row(category: $0.key, amount: $0.value, count: counts[$0.key] ?? 0,
                       share: total > 0 ? $0.value / total : 0) }
            .sorted { $0.amount != $1.amount ? $0.amount > $1.amount : $0.category.rawValue < $1.category.rawValue }

        return MonthlyRecap(month: start, income: income, spent: spent,
                            debtPaid: debtPaid, saved: saved, rows: rows)
    }

    // MARK: Comparing

    /// Change from `previous` in whole percent, or nil when there is nothing to
    /// compare with — a month with no spending makes any change "infinite".
    static func change(_ current: Double, from previous: Double) -> Int? {
        guard previous >= 0.5 else { return nil }
        return Int(((current - previous) / previous * 100).rounded())
    }

    // MARK: Dates

    static func monthStart(of date: Date, cal: Calendar = .current) -> Date {
        cal.safeDate(from: cal.dateComponents([.year, .month], from: date))
    }

    /// The last month that has ended: October, all through November.
    static func lastFinishedMonth(before now: Date, cal: Calendar = .current) -> Date {
        cal.safeDate(byAdding: .month, value: -1, to: monthStart(of: now, cal: cal))
    }

    /// When the next reminder goes off — the 1st at 09:00 — and the month it
    /// is about. Before 09:00 on the 1st that is today, about the month just
    /// ended; it is never about the month it fires in.
    static func nextReminder(after now: Date, cal: Calendar = .current) -> (fire: Date, month: Date)? {
        var comps = DateComponents()
        comps.day = 1
        comps.hour = 9
        comps.minute = 0
        guard let fire = cal.nextDate(after: now, matching: comps, matchingPolicy: .nextTime) else { return nil }
        return (fire, lastFinishedMonth(before: fire, cal: cal))
    }

    /// "2026-10": which month's card has been put in the bell.
    static func key(_ month: Date, cal: Calendar = .current) -> String {
        let c = cal.dateComponents([.year, .month], from: month)
        return String(format: "%04ld-%02ld", c.year ?? 0, c.month ?? 0)
    }

    // MARK: The pot

    /// The rows Statistics reads: the main card and its bill cards, or every
    /// card when no main card has been chosen.
    static func transactions(in cards: [BankCard]) -> [TxRecord] {
        MainCard.potTransactions(in: cards) ?? cards.flatMap(\.transactions)
    }

    /// Statistics' currency: the main card's.
    static func currency(in cards: [BankCard]) -> String {
        MainCard.resolve(in: cards)?.resolvedCurrency ?? CurrencyManager.shared.preferredCurrency
    }

    static func converter(to currency: String) -> (TxRecord) -> Double {
        { tx in
            let from = tx.currency.isEmpty ? currency : tx.currency
            return CurrencyManager.shared.convert(tx.amount, from: from, to: currency)
        }
    }
}

// MARK: - Opened from the reminder

/// Set when the reminder is tapped. On a cold launch the tap is reported before
/// any view is listening, so MainTabView also checks this when it appears and
/// clears it on use — the same hand-off `QuickVoiceRoute` makes.
@MainActor
final class MonthlyRecapRoute {
    static let shared = MonthlyRecapRoute()
    var pending = false
    private init() {}

    func open() {
        pending = true
        NotificationCenter.default.post(name: .requestOpenMonthlyRecap, object: nil)
    }

    /// Reads and clears in one step, so one tap can never open it twice.
    func consume() -> Bool {
        defer { pending = false }
        return pending
    }
}

// MARK: - The bell card

@MainActor
enum MonthlyRecapBell {
    private static let postedKey = "monthly_recap_posted"

    /// Puts last month's card in the bell, once per month. No device push: the
    /// reminder on the 1st is that. Off with the weekly & monthly summary switch.
    static func postIfDue(cards: [BankCard], now: Date = .now) {
        guard NotificationPreferences.shared.isEnabled(.summary) else { return }
        let month = MonthlyRecap.lastFinishedMonth(before: now)
        let key = MonthlyRecap.key(month)
        guard UserDefaults.standard.string(forKey: postedKey) != key else { return }
        let currency = MonthlyRecap.currency(in: cards)
        guard let recap = MonthlyRecap.build(MonthlyRecap.transactions(in: cards), month: month,
                                             convert: MonthlyRecap.converter(to: currency)) else { return }
        UserDefaults.standard.set(key, forKey: postedKey)

        let cm = CurrencyManager.shared
        NotificationManager.shared.post(AppNotificationItem(
            icon: "calendar", iconColorHex: "#38BDF8",
            title: String(format: loc("notif.monthly.title"), monthName(month)),
            body: String(format: loc("notif.monthly.item_body"),
                         cm.formatted(recap.spent, currency: currency),
                         cm.formatted(recap.income, currency: currency)),
            time: loc("notif.time.now"),
            advice: loc("notif.monthly.advice"),
            route: NotificationRoute.monthlyRecap.rawValue
        ), pushToDevice: false)
    }

    /// "Oktober", in the app's language.
    static func monthName(_ month: Date) -> String {
        DateFormatterCache.template("MMMM").string(from: month)
    }
}

// MARK: - The screen

struct MonthlyRecapView: View {
    let cards: [BankCard]
    @Environment(\.dismiss) private var dismiss
    @State private var month = MonthlyRecap.lastFinishedMonth(before: .now)

    private var currency: String { MonthlyRecap.currency(in: cards) }
    private var txs: [TxRecord] { MonthlyRecap.transactions(in: cards) }

    private func recap(_ month: Date, _ txs: [TxRecord]) -> MonthlyRecap? {
        MonthlyRecap.build(txs, month: month, convert: MonthlyRecap.converter(to: currency))
    }
    private func money(_ v: Double) -> String {
        CurrencyManager.shared.formatted(v, currency: currency)
    }
    private var previousMonth: Date { Calendar.current.safeDate(byAdding: .month, value: -1, to: month) }
    private var nextMonth: Date { Calendar.current.safeDate(byAdding: .month, value: 1, to: month) }

    var body: some View {
        let all = txs
        let current = recap(month, all)
        let previous = recap(previousMonth, all)
        let earliest = all.map(\.date).min().map { MonthlyRecap.monthStart(of: $0) }
        let canGoBack = earliest.map { previousMonth >= $0 } ?? false
        let canGoForward = nextMonth <= MonthlyRecap.lastFinishedMonth(before: .now)

        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 12) {
                        header(canGoBack: canGoBack, canGoForward: canGoForward)
                        if let current {
                            totals(current, previous: previous)
                            leftCard(current)
                            if !current.rows.isEmpty { whereItWent(current) }
                            note(current)
                        } else {
                            empty
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .padding(.bottom, 28)
                    .containerRelativeFrame(.horizontal)
                }
            }
            .navigationTitle(loc("recap.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .doneToolbar { dismiss() }
        }
    }

    // MARK: Header

    private var rangeLabel: String {
        let fmt = DateIntervalFormatter()
        fmt.locale = LanguageManager.shared.currentLocale
        fmt.dateTemplate = "dMMMMyyyy"
        let last = Calendar.current.safeDate(byAdding: .day, value: -1, to: nextMonth)
        return fmt.string(from: month, to: last)
    }

    private func header(canGoBack: Bool, canGoForward: Bool) -> some View {
        HStack(alignment: .bottom, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(rangeLabel)
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)
                Text(String(format: loc("recap.headline"), MonthlyRecapBell.monthName(month)))
                    .font(.system(.title2, weight: .heavy))
                    .foregroundStyle(AppTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            HStack(spacing: 8) {
                stepButton("chevron.left", label: loc("recap.prev"), enabled: canGoBack) {
                    month = previousMonth
                }
                stepButton("chevron.right", label: loc("recap.next"), enabled: canGoForward) {
                    month = nextMonth
                }
            }
        }
        .padding(.bottom, 2)
    }

    private func stepButton(_ icon: String, label: String, enabled: Bool,
                            action: @escaping () -> Void) -> some View {
        Button {
            HapticManager.shared.tap()
            withAnimation(.spring(response: 0.35)) { action() }
        } label: {
            Image(systemName: icon)
                .font(.system(.footnote, weight: .bold))
                .foregroundStyle(enabled ? AppTheme.textPrimary : AppTheme.textSecondary.opacity(0.4))
                .frame(width: 34, height: 34)
                .background(AppTheme.cardDark, in: Circle())
        }
        .buttonStyle(ScaleButtonStyle())
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    // MARK: Totals

    private struct Chip {
        let text: String
        let tint: Color
        let neutral: Bool
    }

    /// "Down 8% from Sep". For spending, down is the good news; for income, up.
    private func chip(_ current: Double, _ previous: MonthlyRecap?, value: (MonthlyRecap) -> Double,
                      upIsGood: Bool) -> Chip? {
        guard let previous, let pct = MonthlyRecap.change(current, from: value(previous)) else { return nil }
        let short = DateFormatterCache.template("MMM").string(from: previousMonth)
        if pct == 0 {
            return Chip(text: String(format: loc("recap.same"), short), tint: AppTheme.textSecondary, neutral: true)
        }
        let up = pct > 0
        let text = String(format: loc(up ? "recap.up" : "recap.down"), abs(pct), short)
        if up == upIsGood { return Chip(text: text, tint: AppTheme.accent, neutral: false) }
        // More spending is worth a look, not an alarm; less income is just said.
        return upIsGood ? Chip(text: text, tint: AppTheme.textSecondary, neutral: true)
                        : Chip(text: text, tint: AppTheme.orange, neutral: false)
    }

    private func totals(_ r: MonthlyRecap, previous: MonthlyRecap?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            tile(icon: "arrow.up.right", tint: AppTheme.red, label: loc("recap.spent"), amount: r.spent,
                 chip: chip(r.spent, previous, value: \.spent, upIsGood: false))
            tile(icon: "arrow.down.left", tint: AppTheme.accent, label: loc("recap.income"), amount: r.income,
                 chip: chip(r.income, previous, value: \.income, upIsGood: true))
        }
    }

    private func tile(icon: String, tint: Color, label: String, amount: Double, chip: Chip?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(.caption, weight: .bold))
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
                    .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 9))
                Text(label)
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            Text(money(amount))
                .font(.system(.title3, weight: .bold))
                .foregroundStyle(AppTheme.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.55)
                .contentTransition(.numericText())
            if let chip {
                Text(chip.text)
                    .font(.system(.caption2, weight: .bold))
                    .foregroundStyle(chip.tint)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(chip.neutral ? AppTheme.cardMid : chip.tint.opacity(0.14),
                                in: RoundedRectangle(cornerRadius: AppRadius.xs))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
    }

    private func leftCard(_ r: MonthlyRecap) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(loc(r.left >= 0 ? "recap.left" : "recap.over"))
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(loc("recap.left_sub"))
                    .font(.system(.caption2))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            Spacer(minLength: 8)
            Text((r.left >= 0 ? "+" : "−") + money(abs(r.left)))
                .font(.system(.title3, weight: .bold))
                .foregroundStyle(r.left >= 0 ? AppTheme.accent : AppTheme.red)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .padding(.vertical, 14).padding(.horizontal, 18)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
    }

    // MARK: Where it went

    private func whereItWent(_ r: MonthlyRecap) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(loc("recap.where"))
                    .font(.system(.subheadline, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                Spacer()
                Text(txCountLabel(r.txCount))
                    .font(.system(.caption))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            shareBar(r.rows)
            ForEach(r.rows) { row in
                categoryRow(row, largest: r.rows.first?.amount ?? row.amount)
            }
        }
        .padding(.vertical, 16).padding(.horizontal, 18)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
    }

    /// Every category's part of the month in one line, in the colours the rows use.
    private func shareBar(_ rows: [MonthlyRecap.Row]) -> some View {
        GeometryReader { geo in
            let gap: CGFloat = 2
            let room = max(geo.size.width - gap * CGFloat(max(rows.count - 1, 0)), 0)
            HStack(spacing: gap) {
                ForEach(rows) { row in
                    Rectangle()
                        .fill(Color(hex: row.category.iconBg))
                        .frame(width: max(room * row.share, 3))
                }
            }
            .frame(width: geo.size.width, alignment: .leading)
            .clipShape(Capsule())
        }
        .frame(height: 12)
        .accessibilityHidden(true)
    }

    private func categoryRow(_ row: MonthlyRecap.Row, largest: Double) -> some View {
        let pct = Int((row.share * 100).rounded())
        return HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(Color(hex: row.category.iconBg)).frame(width: 40, height: 40)
                Image(systemName: row.category.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(row.category.displayLabel)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(money(row.amount))
                        .font(.system(.subheadline, weight: .bold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                HStack {
                    Text(txCountLabel(row.count))
                        .font(.system(.caption2))
                        .foregroundStyle(AppTheme.textSecondary)
                    Spacer()
                    Text(pct < 1 ? "<1%" : "\(pct)%")
                        .font(.system(.caption2, weight: .bold))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(AppTheme.cardMid)
                        Capsule().fill(Color(hex: row.category.iconBg))
                            .frame(width: max(geo.size.width * CGFloat(largest > 0 ? row.amount / largest : 0), 6))
                    }
                }
                .frame(height: 6)
                .padding(.top, 3)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.category.displayLabel), \(money(row.amount)), \(pct)%")
    }

    private func txCountLabel(_ n: Int) -> String {
        n == 1 ? loc("recap.tx_one") : String(format: loc("recap.tx_count"), n)
    }

    // MARK: Footnote and empty month

    private func note(_ r: MonthlyRecap) -> some View {
        var lines: [String] = []
        if r.debtPaid >= 0.5 && r.saved >= 0.5 {
            lines.append(String(format: loc("recap.kept_both"), money(r.debtPaid), money(r.saved)))
        } else if r.debtPaid >= 0.5 {
            lines.append(String(format: loc("recap.kept_debt"), money(r.debtPaid)))
        } else if r.saved >= 0.5 {
            lines.append(String(format: loc("recap.kept_saved"), money(r.saved)))
        }
        lines.append(loc("recap.matches"))
        return Text(lines.joined(separator: " "))
            .font(.system(.caption))
            .foregroundStyle(AppTheme.textSecondary)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "calendar")
                .font(.system(.title2, weight: .semibold))
                .foregroundStyle(AppTheme.blue)
                .frame(width: 52, height: 52)
                .background(AppTheme.blue.opacity(0.15), in: Circle())
            Text(String(format: loc("recap.empty"), MonthlyRecapBell.monthName(month)))
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(AppTheme.textPrimary)
                .multilineTextAlignment(.center)
            Text(loc("recap.empty_sub"))
                .font(.system(.caption))
                .foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28).padding(.horizontal, 18)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
    }
}
