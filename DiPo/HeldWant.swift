import Foundation
import SwiftData
import UserNotifications

// MARK: - Wait before buying ("Tahan dulu")
//
// Something wanted, held for a few days before it is bought. A want made on
// the spot — a flash sale, a live-shopping deal, a friend's new phone — often
// fades within days, so the thing waits here with its price instead of going
// into the basket. When the wait is over DiPo asks whether it is still wanted:
// then it is bought with a clear head, or let go and its price stays with the
// user. What was let go adds up in the jar on the Savings Goals screen, and
// can go straight into a goal from there.
//
// A held want moves no money. Buying it is logged like any purchase, when it
// is paid; letting it go into a goal goes through that goal's own deposit.

@Model
final class HeldWant {
    var id: UUID
    var name: String
    var amount: Double
    var currency: String
    var addedAt: Date
    /// The wait chosen, in days. Waiting longer starts one as long again.
    var waitDays: Int
    /// When the wait is over and DiPo asks.
    var readyAt: Date
    /// The `Decision`, once there is one; nil while the want waits.
    var decisionRaw: String?
    var decidedAt: Date?

    init(name: String, amount: Double, currency: String, waitDays: Int, now: Date = .now) {
        self.id = UUID()
        self.name = name
        self.amount = amount
        self.currency = currency
        self.addedAt = now
        self.waitDays = waitDays
        self.readyAt = HeldWant.end(ofWait: waitDays, from: now)
        self.decisionRaw = nil
        self.decidedAt = nil
    }
}

extension HeldWant {
    enum Decision: String {
        /// Still wanted once the wait was over.
        case buy
        /// Not wanted any more: its price stayed with the user.
        case letGo
    }

    /// The waits offered, in days, and the one picked to start with.
    static let waits = [1, 3, 7, 30]
    static let defaultWait = 3

    static func end(ofWait days: Int, from start: Date, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: days, to: start)
            ?? start.addingTimeInterval(TimeInterval(days) * 86_400)
    }

    var decision: Decision? { decisionRaw.flatMap(Decision.init(rawValue:)) }

    /// Decided either way. A decision this build doesn't know (written by a
    /// newer one) still counts as made.
    var isDecided: Bool { decisionRaw != nil }

    /// The wait is over and nothing is decided yet: DiPo asks.
    func isReady(at now: Date = .now) -> Bool { !isDecided && now >= readyAt }

    /// When the current wait began: when it was held, or when "wait
    /// longer" started it again.
    var waitStartedAt: Date {
        Calendar.current.date(byAdding: .day, value: -waitDays, to: readyAt) ?? addedAt
    }

    /// How much of the current wait has passed, from 0 to 1.
    func waited(at now: Date = .now) -> Double {
        let start = waitStartedAt
        let total = readyAt.timeIntervalSince(start)
        guard total > 0 else { return 1 }
        return min(max(now.timeIntervalSince(start) / total, 0), 1)
    }

    /// Whole days since it was held, at least one.
    func daysHeld(at now: Date = .now) -> Int {
        max(1, Calendar.current.dateComponents([.day], from: addedAt, to: now).day ?? 1)
    }

    enum TimeLeft: Equatable {
        case days(Int)
        case hours(Int)
        case soon
    }

    /// What is left of the wait, nil once it is over. Rounded to the nearest
    /// day from a day up, so a three-day wait reads "3 days" when it starts,
    /// then to the nearest hour, then "almost time" in the last half hour.
    func timeLeft(at now: Date = .now) -> TimeLeft? {
        let left = readyAt.timeIntervalSince(now)
        guard left > 0 else { return nil }
        let hours = left / 3_600
        if hours >= 23.5 { return .days(max(1, Int((hours / 24).rounded()))) }
        if hours >= 0.5 { return .hours(max(1, Int(hours.rounded()))) }
        return .soon
    }

    func decide(_ decision: Decision, at date: Date = .now) {
        decisionRaw = decision.rawValue
        decidedAt = date
    }

    /// Back on the list, as if nothing had been decided.
    func undoDecision() {
        decisionRaw = nil
        decidedAt = nil
    }

    /// Another wait as long as the first, from now.
    func waitAgain(from now: Date = .now) {
        readyAt = Self.end(ofWait: waitDays, from: now)
    }

    /// "3 days", "1 day".
    static func waitText(_ days: Int) -> String {
        days == 1 ? loc("hold.wait_days_one") : String(format: loc("hold.wait_days"), days)
    }
}

// MARK: - The jar

/// What the jar shows: the price of everything let go, out of everything
/// decided either way.
struct HoldTally: Equatable {
    /// Let go: the money that stayed, in the currency shown.
    var kept: Double = 0
    /// Everything decided: what was let go and what was bought.
    var decided: Double = 0
    var letGo = 0
    var bought = 0

    /// How full the jar is: the share of what was wanted that stayed.
    var level: Double { decided > 0 ? min(max(kept / decided, 0), 1) : 0 }

    init() {}

    init(_ wants: [HeldWant], convert: (Double, String) -> Double) {
        for want in wants {
            guard let decision = want.decision else { continue }
            let value = convert(want.amount, want.currency)
            decided += value
            switch decision {
            case .letGo: kept += value; letGo += 1
            case .buy: bought += 1
            }
        }
    }
}

// MARK: - Asking when the wait is over

/// One push per want still waiting, when its wait ends: "Still want it?".
/// Rides its own switch in notification settings, and needs Royal like the
/// Savings Goals screen the list lives on.
enum HeldWantReminders {
    struct Planned: Sendable, Equatable {
        let id: String
        let title: String
        let body: String
        let fire: DateComponents
    }

    static let idPrefix = "heldwant_"
    /// A wait that ends at night is asked about at eight in the morning.
    static let quietFrom = 21
    static let quietUntil = 8

    /// The last scheduling pass. Each waits for the one before it, so two
    /// changes in quick succession can't interleave and leave behind a push
    /// for a want that was deleted in between.
    private static var lastPass: Task<Void, Never>?

    static func scheduleAll(wants: [HeldWant]) {
        let enabled = NotificationPreferences.shared.isEnabled(.wants)
            && PremiumManager.shared.canAccess(.savingsGoals)
        let planned = enabled ? plan(wants: wants, now: .now, cal: .current) : []
        let previous = lastPass
        lastPass = Task {
            await previous?.value
            let center = UNUserNotificationCenter.current()
            let stale = await center.pendingNotificationRequests()
                .map(\.identifier).filter { $0.hasPrefix(idPrefix) }
            center.removePendingNotificationRequests(withIdentifiers: stale)
            for p in planned {
                let content = UNMutableNotificationContent()
                content.title = p.title
                content.body = p.body
                content.sound = .dipo
                let trigger = UNCalendarNotificationTrigger(dateMatching: p.fire, repeats: false)
                try? await center.add(UNNotificationRequest(identifier: p.id, content: content, trigger: trigger))
            }
        }
    }

    /// After any change to the list: saved, and the pushes redone from it.
    static func saveAndReschedule(_ context: ModelContext) {
        try? context.save()
        scheduleAll(wants: (try? context.fetch(FetchDescriptor<HeldWant>())) ?? [])
    }

    /// Every push due: wants not decided whose wait ends after `now`.
    static func plan(wants: [HeldWant], now: Date, cal: Calendar) -> [Planned] {
        wants.compactMap { want -> Planned? in
            guard !want.isDecided, want.readyAt > now else { return nil }
            let when = askTime(for: want.readyAt, cal: cal)
            return Planned(id: idPrefix + want.id.uuidString,
                           title: String(format: loc("notif.hold_title"), want.name),
                           body: String(format: loc("notif.hold_body"), HeldWant.waitText(want.waitDays)),
                           fire: cal.dateComponents([.year, .month, .day, .hour, .minute], from: when))
        }
    }

    /// The end of a wait, moved out of the night: before eight it waits for
    /// eight that morning; from nine in the evening, for eight the next.
    static func askTime(for end: Date, cal: Calendar) -> Date {
        let hour = cal.component(.hour, from: end)
        if hour < quietUntil {
            return cal.date(bySettingHour: quietUntil, minute: 0, second: 0, of: end) ?? end
        }
        if hour >= quietFrom, let next = cal.date(byAdding: .day, value: 1, to: end) {
            return cal.date(bySettingHour: quietUntil, minute: 0, second: 0, of: next) ?? end
        }
        return end
    }
}
