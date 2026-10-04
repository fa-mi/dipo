import Foundation
import UserNotifications

// MARK: - Yearly tax reminders (STNK, PBB)
//
// A late STNK costs a fine and a late PBB a surcharge, and both fall once a
// year — the kind of date nobody remembers. Two pushes per asset: a week ahead,
// to find the money, and on the day. They ride the "due dates" switch with
// debt reminders, and need Royal like the assets themselves.

struct AssetTaxReminders {
    struct Planned: Sendable, Equatable {
        let id: String
        let title: String
        let body: String
        let fire: DateComponents
    }

    static let idPrefix = "assettax_"

    @MainActor
    static func scheduleAll(assets: [PhysicalAsset]) {
        let enabled = NotificationPreferences.shared.isEnabled(.debt)
            && PremiumManager.shared.canAccess(.assets)
        let planned = enabled ? plan(assets: assets, now: .now, cal: .current) : []
        Task {
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

    @MainActor
    static func plan(assets: [PhysicalAsset], now: Date, cal: Calendar) -> [Planned] {
        var out: [Planned] = []
        for a in assets {
            guard let tax = a.kind.taxLabel, let set = a.taxDueDate else { continue }
            let due = nextOccurrence(of: set, onOrAfter: now, cal: cal)
            let dateText = due.formatted(.dateTime.day().month(.wide).locale(LanguageManager.shared.currentLocale))
            let steps: [(suffix: String, daysBefore: Int, hour: Int, title: String, body: String)] = [
                ("7d", 7, 9, String(format: loc("notif.asset_tax_week_title"), tax),
                 String(format: loc("notif.asset_tax_week_body"), tax, a.name, dateText)),
                ("due", 0, 8, String(format: loc("notif.asset_tax_today_title"), tax),
                 String(format: loc("notif.asset_tax_today_body"), tax, a.name)),
            ]
            for step in steps {
                let day = cal.date(byAdding: .day, value: -step.daysBefore, to: due) ?? due
                var fire = cal.dateComponents([.year, .month, .day], from: day)
                fire.hour = step.hour
                fire.minute = 0
                guard let when = cal.date(from: fire), when > now else { continue }
                out.append(Planned(id: "\(idPrefix)\(a.id.uuidString)_\(step.suffix)",
                                   title: step.title, body: step.body, fire: fire))
            }
        }
        return out
    }

    /// The next time the day and month of `date` come round, today included.
    /// 29 February falls on 28 February in other years.
    static func nextOccurrence(of date: Date, onOrAfter now: Date, cal: Calendar) -> Date {
        let today = cal.startOfDay(for: now)
        let md = cal.dateComponents([.month, .day], from: date)
        func inYear(_ y: Int) -> Date {
            var c = DateComponents(year: y, month: md.month, day: 1)
            let first = cal.date(from: c) ?? today
            let length = cal.range(of: .day, in: .month, for: first)?.count ?? 28
            c.day = min(md.day ?? 1, length)
            return cal.date(from: c) ?? first
        }
        let year = cal.component(.year, from: today)
        let thisYear = inYear(year)
        return thisYear >= today ? thisYear : inYear(year + 1)
    }
}
