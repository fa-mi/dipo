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

// MARK: - The card on Home

/// DiPo's one line a day: whether today is accounted for, and the question when
/// it is not. Deliberately small — it sits above a list the user came to read,
/// and it has nothing to say on most days beyond one line.
struct DailyCheckInCard: View {
    /// The selected card's rows. Home already has them; recomputing here would
    /// mean a second scan of the ledger on every render.
    let transactions: [TxRecord]

    @Environment(\.modelContext) private var context
    @Query private var checkIns: [DayCheckIn]
    /// Per-device and per-day: dismissing the question is not an answer about
    /// the day, so it must not travel to another device or into a backup.
    @AppStorage("checkin_snoozed_day") private var snoozedDay: String = ""

    private var todayKey: String { DailyCheckIn.key(.now) }
    private var logged: Set<String> { DailyCheckIn.loggedDays(transactions) }
    private var answered: Set<String> { Set(checkIns.map(\.dayKey)) }

    private var today: DayKnowledge {
        DailyCheckIn.knowledge(of: .now, logged: logged, answered: answered)
    }

    private var streak: Int {
        DailyCheckIn.streak(logged: logged, answered: answered)
    }

    private var asking: Bool {
        today == .unknown
            && Calendar.current.component(.hour, from: .now) >= DailyCheckIn.askAfterHour
            && snoozedDay != todayKey
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image("DiPoMascot")
                    .resizable().scaledToFill()
                    .frame(width: 34, height: 34)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if asking {
                        Text(loc("checkin.ask_body"))
                            .font(.system(.caption))
                            .foregroundStyle(AppTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                // Two days is the shortest run that means anything; one day is
                // just "today", which the line already says.
                if streak >= 2 {
                    HStack(spacing: 3) {
                        Image(systemName: "flame.fill").font(.system(.caption2, weight: .bold))
                        Text(String(format: loc("checkin.streak"), streak))
                            .font(.system(.caption2, weight: .bold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(AppTheme.orange)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(AppTheme.orange.opacity(0.13), in: Capsule())
                    .fixedSize()
                }
            }

            if asking {
                HStack(spacing: 8) {
                    Button {
                        HapticManager.shared.success()
                        context.insert(DayCheckIn(dayKey: todayKey))
                        try? context.save()
                    } label: {
                        Text(loc("checkin.none"))
                            .font(.system(.caption, weight: .bold))
                            .foregroundStyle(AppTheme.onVividFill)
                            .frame(maxWidth: .infinity).padding(.vertical, 9)
                            .background(AppTheme.accentFill, in: Capsule())
                    }
                    .buttonStyle(ScaleButtonStyle())
                    Button {
                        HapticManager.shared.tap()
                        snoozedDay = todayKey
                    } label: {
                        Text(loc("checkin.later"))
                            .font(.system(.caption, weight: .semibold))
                            .foregroundStyle(AppTheme.textSecondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 9)
                            .background(AppTheme.cardMid, in: Capsule())
                    }
                    .buttonStyle(ScaleButtonStyle())
                }
            }
        }
        .padding(14)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
        // The evening reminder is the same question as this card, so it has to
        // answer to the same state: no push on a day that is already accounted
        // for. Rescheduled whenever that state changes rather than on a timer.
        .onAppear { refreshReminder() }
        .onChange(of: today) { _, _ in refreshReminder() }
    }

    private var headline: String {
        switch today {
        case .logged:         return loc("checkin.logged")
        case .confirmedEmpty: return loc("checkin.confirmed")
        case .unknown:        return asking ? loc("checkin.ask_title") : loc("checkin.pending")
        }
    }

    private func refreshReminder() {
        NotificationManager.refreshCheckInReminders(accountedToday: today != .unknown)
    }
}
