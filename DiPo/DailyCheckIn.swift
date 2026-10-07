import SwiftUI
import SwiftData

// MARK: - Daily check-in
//
// A day with no transactions is ambiguous, and the app used to settle that
// ambiguity by guessing: no rows meant no spending. So "3 no-spend days this
// week" could describe three careful days or three days the user never opened
// the app, and nothing on screen told them apart. Every figure built on days —
// the weekly average, the daily allowance, the pace line — inherited the guess.
//
// So DiPo asks once, in the evening: was there really nothing, or was it just
// not written down? An answer turns an unknown day into a known one. A day left
// unanswered stays unknown, and the screens that count days say so instead of
// rounding it down to zero.

/// One day the user confirmed as having no spending.
///
/// Only that answer is stored. A day with transactions answers itself, and
/// "later" is the user dismissing a card, not a statement about the day —
/// writing either one down would invent a record of something nobody said.
@Model
final class DayCheckIn {
    /// `yyyy-MM-dd` in the phone's own calendar. A `Date` would carry a time of
    /// day this does not mean, and would land on a different day when read in
    /// another time zone.
    var dayKey: String
    var answeredAt: Date

    init(dayKey: String, answeredAt: Date = .now) {
        self.dayKey = dayKey
        self.answeredAt = answeredAt
    }
}

/// What is known about one day.
enum DayKnowledge {
    /// The day has transactions, so it speaks for itself.
    case logged
    /// No transactions, and the user said there was nothing to log.
    case confirmedEmpty
    /// No transactions and no answer. NOT the same as a day with no spending.
    case unknown
}

enum DailyCheckIn {

    /// The card only asks in the evening. Asking at nine in the morning
    /// whether the whole day was spend-free invites a wrong answer, and a
    /// question that arrives before it can be answered is just nagging.
    static let askAfterHour = 18

    /// How far back the streak and the day index look. Long enough for any
    /// streak worth showing, short enough that Home never scans a whole ledger.
    static let historyDays = 120

    static func key(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The days that carry at least one transaction, as keys. Built once and
    /// passed around rather than filtering the ledger per day.
    static func loggedDays(_ transactions: [TxRecord], now: Date = .now,
                           calendar: Calendar = .current) -> Set<String> {
        let floor = calendar.date(byAdding: .day, value: -historyDays, to: now) ?? .distantPast
        var out: Set<String> = []
        for tx in transactions where tx.date >= floor {
            out.insert(key(tx.date, calendar: calendar))
        }
        return out
    }

    static func knowledge(of day: Date, logged: Set<String>, answered: Set<String>,
                          calendar: Calendar = .current) -> DayKnowledge {
        let k = key(day, calendar: calendar)
        if logged.contains(k) { return .logged }
        if answered.contains(k) { return .confirmedEmpty }
        return .unknown
    }

    /// Consecutive accounted-for days ending today.
    ///
    /// Today counts only once it is accounted for: at nine in the morning with
    /// nothing logged yet, a streak that has just been reset to zero would be
    /// punishing the user for a day that has not happened.
    static func streak(now: Date = .now, logged: Set<String>, answered: Set<String>,
                       calendar: Calendar = .current) -> Int {
        func accounted(_ d: Date) -> Bool {
            knowledge(of: d, logged: logged, answered: answered, calendar: calendar) != .unknown
        }
        var day = calendar.startOfDay(for: now)
        if !accounted(day) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: day) else { return 0 }
            day = yesterday
        }
        var count = 0
        while accounted(day), count < historyDays {
            count += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }
        return count
    }
}

// MARK: - DiPo on Home

/// DiPo at the top of Home, with the daily check-in folded into him: the
/// "Today is logged" card is gone. Whether today is accounted for and the
/// streak sit beside him; the evening question ("nothing logged today —
/// nothing spent, or not written down yet?") is one of his reminders, after
/// unread notifications and before bills and payday.
struct DiPoHomeSection: View {
    let unread: Int
    let bill: DiPoNudge.Bill?
    let daysToPayday: Int?
    let payDate: Date?
    var onAskDiPo: () -> Void
    var onAction: (DiPoNudge.Action) -> Void
    var animates = true

    /// Every account's recent rows, read here rather than handed in. A day
    /// counts as logged when anything was recorded, whichever card paid.
    @Query private var transactions: [TxRecord]
    @Query private var checkIns: [DayCheckIn]
    @Environment(\.modelContext) private var context
    /// Per-device and per-day: dismissing the question is not an answer about
    /// the day, so it must not travel to another device or into a backup.
    @AppStorage("checkin_snoozed_day") private var snoozedDay: String = ""
    @State private var askingNow = false

    init(unread: Int, bill: DiPoNudge.Bill?, daysToPayday: Int?, payDate: Date?,
         animates: Bool = true,
         onAskDiPo: @escaping () -> Void, onAction: @escaping (DiPoNudge.Action) -> Void) {
        self.animates = animates
        self.unread = unread
        self.bill = bill
        self.daysToPayday = daysToPayday
        self.payDate = payDate
        self.onAskDiPo = onAskDiPo
        self.onAction = onAction
        let floor = Calendar.current.date(byAdding: .day, value: -DailyCheckIn.historyDays, to: .now) ?? .distantPast
        _transactions = Query(filter: #Predicate<TxRecord> { $0.date >= floor })
    }

    private var todayKey: String { DailyCheckIn.key(.now) }
    private var logged: Set<String> { DailyCheckIn.loggedDays(transactions) }
    private var answered: Set<String> { Set(checkIns.map(\.dayKey)) }
    private var today: DayKnowledge { DailyCheckIn.knowledge(of: .now, logged: logged, answered: answered) }
    private var asking: Bool {
        today == .unknown
            && Calendar.current.component(.hour, from: .now) >= DailyCheckIn.askAfterHour
            && snoozedDay != todayKey
    }

    /// Today in a few words, for beside DiPo when he has nothing to remind.
    private var status: String? {
        switch today {
        case .logged:         return loc("checkin.logged")
        case .confirmedEmpty: return loc("checkin.confirmed")
        case .unknown:        return nil
        }
    }

    var body: some View {
        DiPoHomeStrip(
            nudges: DiPoNudge.all(unread: unread, checkIn: asking, bill: bill,
                                  daysToPayday: daysToPayday, payDate: payDate),
            status: status,
            onAskDiPo: onAskDiPo,
            onNudge: { action in
                if action == .checkIn { askingNow = true } else { onAction(action) }
            },
            animates: animates)
        .confirmationDialog(loc("checkin.ask_title"), isPresented: $askingNow, titleVisibility: .visible) {
            Button(loc("checkin.none")) {
                HapticManager.shared.success()
                context.insert(DayCheckIn(dayKey: todayKey))
                try? context.save()
            }
            Button(loc("checkin.later")) { snoozedDay = todayKey }
            Button(loc("ai.confirm.cancel"), role: .cancel) {}
        } message: {
            Text(loc("checkin.ask_body"))
        }
        // The evening reminder is the same question, so it answers to the same
        // state: no push on a day that is already accounted for.
        .onAppear { refreshReminder() }
        .onChange(of: today) { _, _ in refreshReminder() }
    }

    private func refreshReminder() {
        NotificationManager.refreshCheckInReminders(accountedToday: today != .unknown)
    }
}

/// The check-in streak, small, beside the greeting in Home's header — a
/// flame and a number. It used to ride in DiPo's bubble, mixed in with
/// whatever he was reminding about.
struct CheckInStreakBadge: View {
    @Query private var transactions: [TxRecord]
    @Query private var checkIns: [DayCheckIn]

    init() {
        let floor = Calendar.current.date(byAdding: .day, value: -DailyCheckIn.historyDays, to: .now) ?? .distantPast
        _transactions = Query(filter: #Predicate<TxRecord> { $0.date >= floor })
    }

    private var streak: Int {
        DailyCheckIn.streak(logged: DailyCheckIn.loggedDays(transactions),
                            answered: Set(checkIns.map(\.dayKey)))
    }

    var body: some View {
        // Two days is the shortest run that means anything.
        if streak >= 2 {
            HStack(spacing: 2) {
                Image(systemName: "flame.fill")
                Text(verbatim: "\(streak)").monospacedDigit()
            }
            .font(.system(.caption2, weight: .bold))
            .foregroundStyle(AppTheme.orange)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(AppTheme.orange.opacity(0.13), in: Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(format: loc("checkin.streak"), streak))
        }
    }
}
