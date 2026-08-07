import SwiftUI
@preconcurrency import UserNotifications
import SwiftData

// MARK: - DiPo Custom Notification Sound
//
// Every standard alert in the app uses this branded chime instead of the
// system "default" sound. The file `dipo-notification.caf` is bundled in
// the app (Copy Bundle Resources). Critical-tier reminders keep
// `.defaultCritical` because that one bypasses Focus/silent mode.
//
// For REMOTE pushes sent by the Cloudflare Worker (`/api/send-push`),
// the matching filename "dipo-notification.caf" must be supplied in the
// APNs payload — see worker `src/index.js`.

extension UNNotificationSound {
    static let dipo = UNNotificationSound(
        named: UNNotificationSoundName("dipo-notification.caf"))
}

// MARK: - In-App Notification Item

/// Where a notification can send the user next. Kept as raw strings on the
/// item so persisted notifications survive adding new routes.
enum NotificationRoute: String {
    case smartBudget
    case debt
    case savingsGoals

    var actionLabel: String {
        switch self {
        case .smartBudget:  return loc("notif.route.budget")
        case .debt:         return loc("notif.route.debt")
        case .savingsGoals: return loc("notif.route.goals")
        }
    }
    var notificationName: Notification.Name {
        switch self {
        case .smartBudget:  return .requestOpenSmartBudget
        case .debt:         return .requestOpenDebt
        case .savingsGoals: return .requestOpenSavingsGoals
        }
    }
}

struct AppNotificationItem: Identifiable, Codable {
    let id: UUID
    let icon: String
    let iconColorHex: String
    let title: String
    let body: String
    let time: String
    let isUrgent: Bool
    var isRead: Bool
    let createdAt: Date
    var imageUrl: String?
    /// Optional "learn more" link the admin can attach — opened from the
    /// notification detail view. Lets a broadcast point at a full article,
    /// promo page, changelog, etc. without cramming everything into `body`.
    var linkUrl: String?

    /// Notification category. `nil`/"general" for normal broadcasts; the app
    /// renders some kinds distinctly. Currently `"ticket_reply"` (an admin
    /// support reply) is shown concisely — single-line body + a "Support"
    /// tag — to set it apart from full-length announcements.
    ///
    /// Optional (not a defaulted non-optional) on purpose: this struct is
    /// persisted to UserDefaults via Codable, and an optional decodes cleanly
    /// to `nil` for items saved before this field existed. A non-optional with
    /// a Swift default would NOT be honored by the synthesized decoder and
    /// would fail to decode old items.
    var kind: String?

    /// What to actually DO about this, in the user's own numbers. An alert that
    /// only states a problem leaves the user to work out the remedy — this
    /// carries the reasoning and the concrete next step. Optional for Codable
    /// back-compat with items saved before it existed.
    var advice: String?

    /// Screen this notification can send the user to (see
    /// `NotificationRoute`). Renders as a button in the detail sheet.
    var route: String?

    /// True when this notification is an admin support-ticket reply.
    var isTicketReply: Bool { kind == "ticket_reply" }

    init(icon: String, iconColorHex: String, title: String, body: String,
         time: String, isUrgent: Bool = false,
         imageUrl: String? = nil, linkUrl: String? = nil,
         kind: String? = nil, advice: String? = nil, route: String? = nil) {
        self.id           = UUID()
        self.icon         = icon
        self.iconColorHex = iconColorHex
        self.title        = title
        self.body         = body
        self.time         = time
        self.isUrgent     = isUrgent
        self.isRead       = false
        self.createdAt    = Date()
        self.imageUrl     = imageUrl
        self.linkUrl      = linkUrl
        self.kind         = kind
        self.advice       = advice
        self.route        = route
    }

    var iconColor: Color { Color(hex: iconColorHex) }
}

// MARK: - Notification Manager

// ✅ @MainActor required: post() calls withAnimation and mutates @Observable state.
// Without it, calls from async contexts (Firestore listener, budget engine) cause
// data races — a purple runtime warning today, a compile error in Swift 6.
@MainActor
@Observable
final class NotificationManager {
    static let shared = NotificationManager()
    private init() { load() }

    var items: [AppNotificationItem] = []
    var unreadCount: Int { items.filter { !$0.isRead }.count }
    var hasUnread: Bool { unreadCount > 0 }

    // MARK: - Post

    /// Add a notification to the in-app center.
    ///
    /// `pushToDevice` (default `true`): also fire an immediate iOS local
    /// push so the notification surfaces on the lock screen / banner — not
    /// just as a silent bump to the bell badge. The app has no auto in-app
    /// toast, so without this an event posted while the user is on another
    /// screen would go completely unseen until they tap the bell.
    ///
    /// Pass `false` from callers that already fire their own device push
    /// (admin reply, ticket status, card expiry, overspend) to avoid a
    /// double banner.
    func post(_ item: AppNotificationItem, pushToDevice: Bool = true) {
        let isDuplicate = items.contains {
            $0.title == item.title && $0.body == item.body &&
            Date().timeIntervalSince($0.createdAt) < 60
        }
        guard !isDuplicate else { return }
        withAnimation(.spring(response: 0.4)) {
            items.insert(item, at: 0)
            if items.count > 50 { items = Array(items.prefix(50)) }
        }
        save()

        if pushToDevice {
            Self.fireImmediateLocalPush(title: item.title, body: item.body)
        }
    }

    /// Fire a one-shot iOS local push ~1s from now. Used by `post()` to
    /// mirror in-app notifications onto the device, and reusable by any
    /// caller that wants an immediate banner. `nonisolated` — only touches
    /// the thread-safe UNUserNotificationCenter.
    nonisolated static func fireImmediateLocalPush(title: String, body: String) {
        let content   = UNMutableNotificationContent()
        content.title = title
        content.body  = body
        content.sound = .dipo
        content.badge = 1
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: "inapp_mirror_\(UUID().uuidString)",
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            )
        )
    }

    /// Seed (or refresh) the in-app payday reminder for one salary schedule.
    ///
    /// IDEMPOTENT — this is re-run every time the notification center opens
    /// (`seedFromSchedules`), so it must NOT stack duplicates. Previously it
    /// went through `post()`, whose duplicate guard only looks back 60s, so
    /// re-opening the bell after a minute kept adding identical "Payday in N
    /// days" rows. We now tag each schedule's reminder with a stable
    /// `kind = "payday:<label>"` and replace any prior reminder for that
    /// schedule in place — fixing both the duplication AND a stale day-count
    /// lingering (e.g. an old "in 7 days" next to the current "in 2 days").
    /// No device push is fired here; the actual payday push reminders are
    /// scheduled separately by NotificationScheduler.
    func postPayday(label: String, amount: String, daysUntil: Int) {
        let key = "payday:\(label)"
        let icon: String, hex: String, title: String, body: String, time: String
        switch daysUntil {
        case 0:
            icon = "banknote.fill"; hex = "#1DB87A"
            title = loc("notif.payday.today_title")
            body  = String(format: loc("notif.payday.today_body"), label, amount)
            time  = loc("notif.time.today")
        case 1:
            icon = "clock.fill"; hex = "#FB923C"
            title = loc("notif.payday.tomorrow_title")
            body  = String(format: loc("notif.payday.tomorrow_body"), label)
            time  = loc("notif.time.tomorrow")
        default:
            icon = "calendar.badge.clock"; hex = "#38BDF8"
            title = String(format: loc("notif.payday.future_title"), daysUntil)
            body  = String(format: loc("notif.payday.future_body"), label)
            time  = String(format: loc("notif.time.in_days"), daysUntil)
        }

        // Already showing this exact reminder → no-op (avoids needless redraws).
        if let existing = items.first(where: { $0.kind == key }),
           existing.title == title, existing.body == body {
            return
        }

        // Bodies any prior payday row for THIS schedule could have — used to
        // also sweep up legacy duplicates created before `kind` tagging existed
        // (they have kind == nil). The "future" body is identical for every
        // day-count ≥ 2, so this catches the stacked "in N days" rows.
        let legacyBodies: Set<String> = [
            String(format: loc("notif.payday.future_body"), label),
            String(format: loc("notif.payday.tomorrow_body"), label),
            String(format: loc("notif.payday.today_body"), label, amount),
        ]
        let wasRead = items.first(where: { $0.kind == key })?.isRead ?? false

        withAnimation(.spring(response: 0.4)) {
            items.removeAll { $0.kind == key || ($0.kind == nil && legacyBodies.contains($0.body)) }
            var item = AppNotificationItem(
                icon: icon, iconColorHex: hex, title: title, body: body,
                time: time, isUrgent: daysUntil <= 1, kind: key)
            item.isRead = wasRead
            items.insert(item, at: 0)
            if items.count > 50 { items = Array(items.prefix(50)) }
        }
        save()
    }

    /// Smart Budget over-budget alert for one group (Daily needs / Lifestyle).
    /// Fires a device push + an in-app bell item, at most once per pay-cycle per
    /// group (`cycleKey` identifies the current cycle). Previously this method
    /// existed but was never called — so users never got an over-budget alert
    /// even while the Smart Budget screen showed "over budget" in red.
    /// - Parameters:
    ///   - overAmount: how much past the target, in money. A percentage alone
    ///     ("1% above") tells the user nothing they can act on — Rp 82.000 does.
    ///   - advice: reasoning plus the concrete next step, already formatted.
    static func postBudgetGroupAlert(group: String, overAmount: Double, limit: Double,
                                     currency: String, cycleKey: String,
                                     advice: String) {
        let dedupKey = "budget_alert_\(group.lowercased())_\(cycleKey)"
        guard !UserDefaults.standard.bool(forKey: dedupKey) else { return }
        UserDefaults.standard.set(true, forKey: dedupKey)

        let cm = CurrencyManager.shared
        let title = String(format: loc("notif.budget_alert_title"), group)
        let body  = String(format: loc("notif.budget_alert_body"),
                           cm.formatted(overAmount, currency: currency),
                           group.lowercased(),
                           cm.formatted(limit, currency: currency))

        let content   = UNMutableNotificationContent()
        content.title = title
        content.body  = body
        content.sound = .dipo
        content.badge = 1
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: "smart_\(dedupKey)",
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
            )
        )

        NotificationManager.shared.post(AppNotificationItem(
            icon: "exclamationmark.triangle.fill", iconColorHex: "#FF6B6B",
            title: title, body: body, time: loc("notif.time.now"), isUrgent: true,
            advice: advice, route: NotificationRoute.smartBudget.rawValue
        ), pushToDevice: false)
    }

    /// - Parameters:
    ///   - advice: reasoning + next step. Missing a due date has a real cost
    ///     (late fees, and on a revolving card, interest), so the reminder
    ///     should say what happens and where to act — not just the date.
    func postDebtReminder(name: String, amount: String, dueDay: Int,
                          advice: String? = nil) {
        post(AppNotificationItem(icon: "creditcard.trianglebadge.exclamationmark", iconColorHex: "#FF6B6B",
            title: loc("notif.debt_due_title"),
            body:  String(format: loc("notif.debt_due_body"), name, amount, dueDay),
            time:  loc("notif.time.upcoming"), isUrgent: true,
            advice: advice, route: NotificationRoute.debt.rawValue))
    }

    func postSavingsGoalReached(name: String, emoji: String, advice: String? = nil) {
        post(AppNotificationItem(icon: "star.fill", iconColorHex: "#FB923C",
            title: String(format: loc("notif.goal_reached_title"), emoji),
            body:  String(format: loc("notif.goal_reached_body"), name),
            time:  loc("notif.time.now"), isUrgent: true,
            advice: advice, route: NotificationRoute.savingsGoals.rawValue))
    }

    func postSmartInsight(title: String, body: String) {
        // title/body are already provided localized by the caller (SmartBudget
        // engine reads loc keys when building insights). The "Now" tag is the
        // only thing this method controls.
        post(AppNotificationItem(icon: "brain.fill", iconColorHex: "#A78BFA",
            title: title, body: body, time: loc("notif.time.now")))
    }

    // Admin support reply — posted when Firestore listener detects a new unread reply.
    // Also fires a local push notification so the user sees it even when the app is in background.
    // ✅ Fired when admin changes ticket status (open → answered / answered → closed).
    // Shows both in-app notification and a local push.
    func postTicketStatusChanged(subject: String, newStatus: String) {
        let title: String
        let body:  String
        let icon:  String
        let hex:   String

        switch newStatus {
        case "answered":
            // Was using `salary.answered` (typo — that key doesn't exist) so
            // the title rendered the literal raw key string in production.
            // `notif.answered` is the right canonical key for ticket status.
            title = loc("notif.answered")
            body  = loc("notif.answeredbody")
            icon  = "checkmark.circle.fill"
            hex   = "#1DB87A"
        case "closed":
            title = loc("notif.closed")
            body  = loc("notif.closedbody")
            icon  = "archivebox.fill"
            hex   = "#8A9693"
        default:
            // Same fix here: was `salary.answered` with the new status as
            // the format arg, but the body should just describe the new
            // status. `notif.updatedbody` already has the %@ placeholder.
            title = loc("notif.updated")
            body  = String(format: loc("notif.updatedbody"), newStatus)
            icon  = "clock.fill"
            hex   = "#FB923C"
        }

        // pushToDevice:false — own push fired just below.
        post(AppNotificationItem(
            icon: icon, iconColorHex: hex,
            title: title, body: body,
            time: loc("notif.time.now"), isUrgent: newStatus == "answered"
        ), pushToDevice: false)

        let content   = UNMutableNotificationContent()
        content.title = title
        content.body  = body
        content.sound = .dipo
        let trigger   = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "ticket_status_\(UUID().uuidString)", content: content, trigger: trigger)
        )
    }

    // ✅ Fired immediately when a ticket is successfully submitted.
    func postTicketCreated(subject: String) {
        post(AppNotificationItem(
            icon:         "tray.fill",
            iconColorHex: "#38BDF8",
            title:        loc("notif.submited"),
            body:         loc("notif.submitedbody"),
            time:         loc("notif.submitedtime"),
            isUrgent:     false
        ))
    }

    func markAllRead() {
        withAnimation { items = items.map { var i = $0; i.isRead = true; return i } }
        save()
        syncAppBadge()
    }

    func markRead(_ id: UUID) {
        if let idx = items.firstIndex(where: { $0.id == id }) {
            items[idx].isRead = true
            save()
            syncAppBadge()
        }
    }

    func clearAll() {
        withAnimation { items = [] }
        save()
        syncAppBadge()
    }

    /// Reconcile the iOS app-icon badge with the REAL in-app unread count.
    ///
    /// Local pushes hard-code `badge = 1` ("you have something new"), but
    /// nothing ever reset it — so the icon kept showing "1" forever even when
    /// the bell was empty. This sets the OS badge to the actual unread count
    /// (0 → badge disappears). Call on app foreground and whenever unread
    /// changes. Also clears stale delivered notifications from Notification
    /// Center when nothing is unread, so the badge and the center agree.
    func syncAppBadge() {
        let count = unreadCount
        let center = UNUserNotificationCenter.current()
        center.setBadgeCount(count) { _ in }
        if count == 0 {
            center.removeAllDeliveredNotifications()
        }
    }

    // MARK: - Persistence

    private let kKey = "app_notifications_v2"

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: kKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: kKey),
              let decoded = try? JSONDecoder().decode([AppNotificationItem].self, from: data)
        else { return }
        items = decoded
    }

    // MARK: - Daily Reminder (iOS push at 9 PM)

    // ✅ nonisolated: these only call UNUserNotificationCenter, no @Observable state.
    // Without nonisolated, calling from a non-isolated context (e.g. the notification
    // permission callback in RootView) would require await and cause a compile warning.
    nonisolated static func scheduleDailyReminder() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["daily_reminder"])
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("notif.dailycheckin", comment: "")
        content.body  = NSLocalizedString("notif.dailycheckinbody", comment: "")
        content.sound = .dipo
        var comps = DateComponents()
        comps.hour = 21; comps.minute = 0
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        center.add(UNNotificationRequest(identifier: "daily_reminder", content: content, trigger: trigger))
    }

    nonisolated static func cancelDailyReminder() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: ["daily_reminder"])
    }

    /// Call once at app start (from RootView.onAppear).
    /// Requests push permission + registers for remote APNs so FCM can get a token.
    @MainActor
    static func registerForRemotePushNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    /// Schedule expiry reminders for ALL cards. Call on app launch and when any card is edited.
    /// Expired/urgent cards get daily repeating notifications until the user updates the card.
    @MainActor
    static func scheduleCardExpiryReminders(for cards: [BankCard]) {
        let center = UNUserNotificationCenter.current()
        // Remove all previous card expiry notifications before rebuilding
        center.getPendingNotificationRequests { requests in
            let ids = requests.map(\.identifier).filter { $0.hasPrefix("card_expiry_") }
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
        for card in cards {
            guard !card.isDigitalWallet else { continue }
            scheduleExpiryNotificationsForCard(card)
        }
    }

    private static func scheduleExpiryNotificationsForCard(_ card: BankCard) {
        guard let days = card.daysUntilExpiry else { return }
        let status = card.expiryStatus
        guard status != .ok else { return }

        let center  = UNUserNotificationCenter.current()
        let last4   = card.last4
        let baseID  = "card_expiry_\(card.id.uuidString)"

        let content      = UNMutableNotificationContent()
        content.sound    = .dipo
        content.badge    = 1
        content.userInfo = ["cardId": card.id.uuidString]

        switch status {
        case .expired:
            content.title = loc("notif.card_expired_push_title")
            content.body  = String(format: loc("notif.card_expired_push_body"), last4)
            center.add(UNNotificationRequest(identifier: baseID + "_now",
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)))
            var dc = DateComponents(); dc.hour = 9; dc.minute = 0
            center.add(UNNotificationRequest(identifier: baseID + "_daily",
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: dc, repeats: true)))

        case .urgent:
            content.title = String(format: loc("notif.card_urgent_push_title"), days)
            content.body  = String(format: loc("notif.card_urgent_push_body"), last4)
            center.add(UNNotificationRequest(identifier: baseID + "_urgent",
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)))
            var dc = DateComponents(); dc.hour = 9; dc.minute = 0
            center.add(UNNotificationRequest(identifier: baseID + "_daily",
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: dc, repeats: true)))

        case .soon:
            content.title = String(format: loc("notif.card_warning_push_title"), days)
            content.body  = String(format: loc("notif.card_warning_push_body"), last4, card.expireDate)
            center.add(UNNotificationRequest(identifier: baseID + "_soon",
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)))
            var dc = DateComponents(); dc.weekday = 2; dc.hour = 9; dc.minute = 0
            center.add(UNNotificationRequest(identifier: baseID + "_weekly",
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: dc, repeats: true)))

        case .ok: break
        }

        // Also post in-app notification for expired/urgent.
        // pushToDevice:false — this card already has its own scheduled
        // device pushes above (the `_now` / `_daily` triggers), so letting
        // post() add another immediate push would double up.
        if status == .expired || status == .urgent {
            Task { @MainActor in
                NotificationManager.shared.post(AppNotificationItem(
                    icon:         status == .expired ? "xmark.circle.fill" : "exclamationmark.triangle.fill",
                    iconColorHex: "#FF5B5B",
                    title:        status == .expired
                        ? String(format: loc("notif.card_expired_inapp_title"), last4)
                        : String(format: loc("notif.card_expiring_inapp_title"), last4, days),
                    body:         status == .expired
                        ? loc("notif.card_expired_inapp_body")
                        : loc("notif.card_expiring_inapp_body"),
                    time:         loc("notif.time.now"),
                    isUrgent:     true
                ), pushToDevice: false)
            }
        }
    }

    /// Call when a card is successfully updated — cancels all its expiry reminders.
    static func cancelCardExpiryReminders(for cardID: UUID) {
        let id = "card_expiry_\(cardID.uuidString)"
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [id+"_now", id+"_daily", id+"_urgent", id+"_weekly", id+"_soon"]
        )
    }

    /// Schedule both in-app + device notifications for upcoming salary.
    /// Fires: 3 days before AND 1 day before the actual payday.
    /// Call this whenever a salary schedule is added or updated.
    @MainActor
    static func scheduleSalaryReminders(dayOfMonth: Int, label: String, amount: String) {
        let center = UNUserNotificationCenter.current()

        // Remove any old salary reminders before re-scheduling
        center.removePendingNotificationRequests(withIdentifiers: [
            "salary_reminder_3d", "salary_reminder_1d"
        ])

        let cal      = Calendar.current
        let today    = cal.startOfDay(for: .now)
        let payDate  = SalaryDateEngine.nextPayDate(dayOfMonth: dayOfMonth)
        let daysLeft = cal.dateComponents([.day], from: today, to: payDate).day ?? 0

        // Schedule 3-day reminder
        if daysLeft >= 3 {
            if let fireDate = cal.date(byAdding: .day, value: -3, to: payDate) {
                scheduleLocalPush(
                    id:      "salary_reminder_3d",
                    title:   "💸 Salary incoming in 3 days!",
                    body:    "\(label) • \(amount) — arrives \(payDate.formatted(date: .abbreviated, time: .omitted))",
                    at:      fireDate
                )
            }
        }

        // Schedule 1-day reminder (eve of payday)
        if daysLeft >= 1 {
            if let fireDate = cal.date(byAdding: .day, value: -1, to: payDate) {
                scheduleLocalPush(
                    id:      "salary_reminder_1d",
                    title:   "🎉 Payday is tomorrow!",
                    body:    "\(label) • \(amount) drops on \(payDate.formatted(.dateTime.weekday(.wide)))",
                    at:      fireDate
                )
            }
        }
    }

    // `nonisolated` — only touches UNUserNotificationCenter (thread-safe),
    // so it can be called from the nonisolated smart-reminder schedulers
    // below as well as the @MainActor salary scheduler above.
    nonisolated private static func scheduleLocalPush(id: String, title: String, body: String, at date: Date) {
        let content       = UNMutableNotificationContent()
        content.title     = title
        content.body      = body
        content.sound     = .dipo
        content.badge     = 1

        let comps   = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        )
    }

    // MARK: - Smart Reminders (weekly / monthly / inactivity / overspend)
    //
    // These are all scheduled as ONE-SHOT triggers and re-scheduled on every
    // app foreground (see NotificationScheduler.refresh). One-shot rather
    // than `repeats: true` because the notification body bakes in live
    // numbers ("you spent Rp X") — a repeating trigger would freeze stale
    // content forever. Re-scheduling on foreground keeps the numbers fresh
    // up to the user's last app open, which is good enough for a recap.

    /// Weekly spending recap — fires the upcoming Sunday at 20:00.
    /// `deltaText` is an optional "+12% vs last week" style comparison.
    nonisolated static func scheduleWeeklyRecap(expensesFormatted: String, deltaText: String?) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["smart_weekly_recap"])

        let cal = Calendar.current
        // Find the next Sunday 20:00. weekday == 1 is Sunday in Gregorian.
        var comps = DateComponents()
        comps.weekday = 1
        comps.hour    = 20
        comps.minute  = 0
        guard let fireDate = cal.nextDate(after: .now, matching: comps,
                                          matchingPolicy: .nextTime) else { return }

        var body = String(format: loc("notif.weekly.body"), expensesFormatted)
        if let deltaText { body += " " + deltaText }

        scheduleLocalPush(id: "smart_weekly_recap",
                          title: loc("notif.weekly.title"),
                          body:  body,
                          at:    fireDate)
    }

    /// Monthly summary — fires the 1st of next month at 09:00.
    nonisolated static func scheduleMonthlySummary(incomeFormatted: String,
                                                   expenseFormatted: String,
                                                   topCategory: String?) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["smart_monthly_summary"])

        let cal = Calendar.current
        var comps = DateComponents()
        comps.day    = 1
        comps.hour   = 9
        comps.minute = 0
        guard let fireDate = cal.nextDate(after: .now, matching: comps,
                                          matchingPolicy: .nextTime) else { return }

        var body = String(format: loc("notif.monthly.body"), incomeFormatted, expenseFormatted)
        if let topCategory, !topCategory.isEmpty {
            body += " " + String(format: loc("notif.monthly.top"), topCategory)
        }

        scheduleLocalPush(id: "smart_monthly_summary",
                          title: loc("notif.monthly.title"),
                          body:  body,
                          at:    fireDate)
    }

    /// Inactivity nudge — fires 3 days after the user's last transaction,
    /// at 19:00. Skipped when there are no transactions, or when the
    /// 3-day mark is already in the past (user is already overdue — a late
    /// nudge would feel broken; the next tx they add reschedules it).
    nonisolated static func scheduleInactivityNudge(lastTxDate: Date?) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["smart_inactivity"])

        guard let lastTxDate else { return }
        let cal = Calendar.current
        guard let plus3 = cal.date(byAdding: .day, value: 3, to: lastTxDate) else { return }
        // Pin to 19:00 on that day.
        var dc = cal.dateComponents([.year, .month, .day], from: plus3)
        dc.hour = 19; dc.minute = 0
        guard let fireDate = cal.date(from: dc), fireDate > .now else { return }

        scheduleLocalPush(id: "smart_inactivity",
                          title: loc("notif.inactivity.title"),
                          body:  loc("notif.inactivity.body"),
                          at:    fireDate)
    }

    /// Overspend alert — when this month's expenses exceed income. Fires a
    /// device push almost immediately (5s) AND posts an in-app item.
    /// De-duplicated to once per calendar day via UserDefaults so a user
    /// who opens the app five times doesn't get spammed.
    @MainActor
    /// - Parameters:
    ///   - topCategory: biggest spending category this month, if known.
    ///   - topCategoryAmount: what it cost. Naming the driver is the only
    ///     actionable thing available to a free user here — Smart Budget's
    ///     shift-the-split advice is Royal-only, but "Food & Drinks is Rp X of
    ///     it" is something anyone can act on.
    static func checkOverspendPush(income: Double, expense: Double, currencyCode: String,
                                   topCategory: String? = nil,
                                   topCategoryAmount: Double = 0) {
        guard income > 0, expense > income else { return }

        // Once-per-day dedup. Key holds the yyyy-MM-dd of the last push.
        let todayKey = ISO8601DateFormatter.dayString(from: .now)
        let lastKey  = UserDefaults.standard.string(forKey: "overspend_push_day")
        guard lastKey != todayKey else { return }
        UserDefaults.standard.set(todayKey, forKey: "overspend_push_day")

        let overBy = CurrencyManager.shared.formatted(expense - income, currency: currencyCode)

        // Device push (visible even when app is closed).
        let content   = UNMutableNotificationContent()
        content.title = loc("notif.overspend.title")
        content.body  = String(format: loc("notif.overspend.body"), overBy)
        content.sound = .dipo
        content.badge = 1
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: "smart_overspend_\(todayKey)",
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
            )
        )

        // In-app item too — so it shows in the notification center bell.
        // pushToDevice:false — the device push was already fired above.
        let cm = CurrencyManager.shared
        let advice: String = {
            if let topCategory, topCategoryAmount > 0 {
                let share = expense > 0 ? Int((topCategoryAmount / expense * 100).rounded()) : 0
                return String(format: loc("notif.overspend_advice_category"),
                              topCategory,
                              cm.formatted(topCategoryAmount, currency: currencyCode),
                              share, overBy)
            }
            return String(format: loc("notif.overspend_advice_generic"), overBy)
        }()

        NotificationManager.shared.post(AppNotificationItem(
            icon: "exclamationmark.triangle.fill", iconColorHex: "#FF5B5B",
            title: loc("notif.overspend.title"),
            body:  String(format: loc("notif.overspend.body"), overBy),
            time:  loc("notif.time.now"), isUrgent: true,
            advice: advice
        ), pushToDevice: false)
    }
}

// MARK: - ISO8601 Day Helper

extension ISO8601DateFormatter {
    /// "2026-05-16" style key — used for once-per-day notification dedup.
    static func dayString(from date: Date) -> String {
        let f = DateFormatter()
        f.locale     = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}

// MARK: - Notification Center View

struct NotificationCenterView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \SalarySchedule.createdAt) private var schedules: [SalarySchedule]
    @State private var mgr = NotificationManager.shared
    /// Drives the detail sheet — set on row tap. `AppNotificationItem` is
    /// Identifiable so `.sheet(item:)` binds to it directly.
    @State private var selectedItem: AppNotificationItem?

    var body: some View {
        // Using NavigationStack so the nav bar fills the top — eliminates the dead space
        // that appeared when using a manual HStack header inside a bare sheet.
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                if mgr.items.isEmpty {
                    emptyState
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 12) {
                            ForEach(mgr.items) { item in
                                notifRow(item)
                                    .padding(.horizontal, 22)
                                    .onTapGesture {
                                        mgr.markRead(item.id)
                                        selectedItem = item
                                    }
                            }
                            Spacer(minLength: 40)
                        }
                        .padding(.top, 8)
                    }
                }
            }
            .navigationTitle(loc("notif.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc("common.done")) {
                        mgr.markAllRead()
                        dismiss()
                    }
                    .foregroundStyle(AppTheme.textSecondary)
                }
                ToolbarItem(placement: .primaryAction) {
                    if !mgr.items.isEmpty {
                        Button(loc("common.clear")) { mgr.clearAll() }
                            .foregroundStyle(AppTheme.red)
                            .font(.system(size: 13))
                    }
                }
            }
        }
        .onAppear { seedFromSchedules() }
        // Tap a row → full detail (bigger image, full text, "learn more").
        .sheet(item: $selectedItem) { item in
            NotificationDetailView(item: item)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
                .preferredColorScheme(appColorScheme())
        }
    }

    @ViewBuilder
    private func notifRow(_ item: AppNotificationItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(item.iconColor.opacity(0.15)).frame(width: 44, height: 44)
                    Image(systemName: item.icon).font(.system(size: 20)).foregroundStyle(item.iconColor)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(item.title)
                            .font(.system(size: 15, weight: item.isRead ? .regular : .semibold))
                            .foregroundStyle(item.isRead ? AppTheme.textSecondary : AppTheme.textPrimary)
                        // Distinguish support replies at a glance with a small tag.
                        if item.isTicketReply {
                            Text(loc("notif.tag.support"))
                                .font(.system(size: 9, weight: .bold))
                                .tracking(0.4)
                                .foregroundStyle(item.iconColor)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(item.iconColor.opacity(0.15), in: Capsule())
                        }
                        Spacer()
                        if !item.isRead {
                            Circle().fill(item.iconColor).frame(width: 8, height: 8)
                        }
                        Text(item.time).font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
                    }
                    // Ticket replies stay concise in the list (one truncated
                    // line) — the full reply is shown when the row is tapped
                    // (detail view) and lives in the support ticket thread.
                    // Other notifications keep their full body.
                    Text(item.body)
                        .font(.system(size: 13))
                        .foregroundStyle(AppTheme.textSecondary)
                        .lineSpacing(2)
                        .lineLimit(item.isTicketReply ? 1 : nil)
                        .truncationMode(.tail)
                }
            }
            if let urlStr = item.imageUrl, let url = URL(string: urlStr) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                            .frame(maxWidth: .infinity).frame(height: 160)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    case .failure:
                        EmptyView()
                    default:
                        RoundedRectangle(cornerRadius: 10)
                            .fill(AppTheme.cardDark)
                            .frame(maxWidth: .infinity).frame(height: 160)
                            .overlay(ProgressView())
                    }
                }
                .padding(.top, 10)
            }
        }
        .padding(14)
        .background(
            item.isUrgent && !item.isRead ? item.iconColor.opacity(0.06) : AppTheme.cardDark,
            in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .stroke(item.isUrgent && !item.isRead ? item.iconColor.opacity(0.2) : Color.clear, lineWidth: 1))
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "bell.slash").font(.system(size: 40)).foregroundStyle(AppTheme.textSecondary)
                .gentleFloat()
            Text(loc("notif.empty")).font(.system(size: 16, weight: .medium)).foregroundStyle(AppTheme.textSecondary)
            Text(loc("notif.info"))
                .font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary.opacity(0.7))
                .multilineTextAlignment(.center)
        }
    }

    private func seedFromSchedules() {
        for s in schedules where s.isActive {
            let days = SalaryDateEngine.daysUntilPay(dayOfMonth: s.dayOfMonth)
            if days <= 7 {
                let amt = CurrencyManager.shared.formatted(s.amount, currency: s.currency)
                mgr.postPayday(label: s.label, amount: amt, daysUntil: days)
            }
        }
    }
}

// MARK: - Notification Detail View
//
// Full-screen detail for a tapped notification. Where the row in
// NotificationCenterView is a compact summary, this shows everything the
// admin attached: the full (untruncated) message, a large image, and an
// optional "learn more" link button. Reached by tapping any notification.

struct NotificationDetailView: View {
    let item: AppNotificationItem
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    /// Parsed link — only render the button when the admin supplied a
    /// well-formed URL, so a typo'd value doesn't show a dead button.
    private var link: URL? {
        guard let raw = item.linkUrl, !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {

                        // Header: icon + title + timestamp
                        HStack(alignment: .top, spacing: 14) {
                            ZStack {
                                Circle()
                                    .fill(item.iconColor.opacity(0.15))
                                    .frame(width: 54, height: 54)
                                Image(systemName: item.icon)
                                    .font(.system(size: 24))
                                    .foregroundStyle(item.iconColor)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title)
                                    .font(.system(size: 20, weight: .bold))
                                    .foregroundStyle(AppTheme.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(item.time)
                                    .font(.system(size: 12))
                                    .foregroundStyle(AppTheme.textSecondary)
                            }
                            Spacer(minLength: 0)
                        }

                        // Large image (if the admin attached one).
                        if let urlStr = item.imageUrl, let url = URL(string: urlStr) {
                            AsyncImage(url: url) { phase in
                                switch phase {
                                case .success(let image):
                                    image.resizable().scaledToFit()
                                        .clipShape(RoundedRectangle(cornerRadius: 14))
                                case .failure:
                                    // Broken URL / offline — show a tappable
                                    // retry-ish placeholder instead of a blank.
                                    RoundedRectangle(cornerRadius: 14)
                                        .fill(AppTheme.cardDark)
                                        .frame(height: 180)
                                        .overlay(
                                            VStack(spacing: 6) {
                                                Image(systemName: "photo")
                                                    .font(.system(size: 26))
                                                Text(loc("notif.image_failed"))
                                                    .font(.system(size: 12))
                                            }
                                            .foregroundStyle(AppTheme.textSecondary)
                                        )
                                default:
                                    RoundedRectangle(cornerRadius: 14)
                                        .fill(AppTheme.cardDark)
                                        .frame(height: 180)
                                        .overlay(ProgressView())
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }

                        // Full message body — selectable so users can copy
                        // codes / details the admin sends.
                        if !item.body.isEmpty {
                            Text(item.body)
                                .font(.system(size: 15))
                                .foregroundStyle(AppTheme.textPrimary)
                                .lineSpacing(4)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        // Reasoning + the concrete next step. An alert that only
                        // states a problem makes the user work out the remedy
                        // themselves; this is what turns the bell into a
                        // decision aid rather than a scoreboard.
                        if let advice = item.advice, !advice.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 7) {
                                    Image(systemName: "lightbulb.fill")
                                        .font(.system(size: 13))
                                        .foregroundStyle(AppTheme.orange)
                                    Text(loc("notif.advice_title"))
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(AppTheme.textPrimary)
                                }
                                Text(advice)
                                    .font(.system(size: 14))
                                    .foregroundStyle(AppTheme.textSecondary)
                                    .lineSpacing(3)
                                    .fixedSize(horizontal: false, vertical: true)

                                if let routeRaw = item.route,
                                   let route = NotificationRoute(rawValue: routeRaw) {
                                    Button {
                                        HapticManager.shared.tap()
                                        // Dismiss first so the destination sheet
                                        // isn't presented behind this one.
                                        dismiss()
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                            NotificationCenter.default.post(
                                                name: route.notificationName, object: nil)
                                        }
                                    } label: {
                                        HStack(spacing: 8) {
                                            Text(route.actionLabel)
                                                .font(.system(size: 14, weight: .semibold))
                                            Image(systemName: "arrow.right")
                                                .font(.system(size: 12, weight: .semibold))
                                        }
                                        .foregroundStyle(.white)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 13)
                                        .background(AppTheme.purple, in: Capsule())
                                    }
                                    .buttonStyle(ScaleButtonStyle())
                                    .padding(.top, 4)
                                }
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(AppTheme.orange.opacity(0.08),
                                        in: RoundedRectangle(cornerRadius: 16))
                        }

                        // "Learn more" link button — only when a valid URL
                        // is attached.
                        if let link {
                            Button {
                                HapticManager.shared.tap()
                                openURL(link)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: item.isTicketReply ? "bubble.left.and.bubble.right.fill" : "safari.fill")
                                        .font(.system(size: 15))
                                    Text(item.isTicketReply ? loc("notif.view_ticket") : loc("notif.learn_more"))
                                        .font(.system(size: 15, weight: .semibold))
                                    Spacer()
                                    Image(systemName: "arrow.up.right")
                                        .font(.system(size: 13, weight: .semibold))
                                }
                                .foregroundStyle(.white)
                                .padding(.vertical, 15)
                                .padding(.horizontal, 18)
                                .background(
                                    LinearGradient(
                                        colors: [item.iconColor, item.iconColor.opacity(0.78)],
                                        startPoint: .leading, endPoint: .trailing
                                    ),
                                    in: RoundedRectangle(cornerRadius: 14)
                                )
                            }
                            .buttonStyle(ScaleButtonStyle())
                        }

                        Spacer(minLength: 20)
                    }
                    .padding(22)
                }
            }
            .navigationTitle(loc("notif.detail_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(loc("common.done")) { dismiss() }
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }
        }
    }
}

// MARK: - Notification Scheduler
//
// Single entry point that reads SwiftData, computes the numbers the smart
// reminders need, and (re)schedules them. Call `refresh(context:)` on app
// launch, on foreground, and after a transaction changes — same cadence as
// `WidgetDataSync.refresh`. Cheap: a couple of fetches + arithmetic.

@MainActor
enum NotificationScheduler {

    /// Recompute + reschedule all smart reminders from current data.
    static func refresh(context: ModelContext) {
        let txs: [TxRecord] = (try? context.fetch(FetchDescriptor<TxRecord>())) ?? []

        let cal       = Calendar.current
        let now       = Date()
        let preferred = CurrencyManager.shared.preferredCurrency

        // Converts a tx into the user's preferred currency, mirroring the
        // logic in StatisticsView / WidgetDataSync so every surface agrees.
        func converted(_ tx: TxRecord) -> Double {
            let c = tx.currency.isEmpty ? preferred : tx.currency
            return CurrencyManager.shared.convert(tx.amount, from: c, to: preferred)
        }

        // ── Weekly recap ───────────────────────────────────────────────
        // Compare expenses in the last 7 days vs the 7 days before that.
        let weekAgo  = cal.date(byAdding: .day, value: -7,  to: now) ?? now
        let twoWkAgo = cal.date(byAdding: .day, value: -14, to: now) ?? now
        var thisWeek = 0.0
        var lastWeek = 0.0
        for tx in txs where tx.txSubtype != .transfer && converted(tx) < 0 {
            let amt = abs(converted(tx))
            if tx.date >= weekAgo {
                thisWeek += amt
            } else if tx.date >= twoWkAgo {
                lastWeek += amt
            }
        }
        let weeklyDelta: String? = {
            guard lastWeek > 0 else { return nil }
            let pct = Int(((thisWeek - lastWeek) / lastWeek * 100).rounded())
            if pct > 0 { return String(format: loc("notif.weekly.up"),   pct) }
            if pct < 0 { return String(format: loc("notif.weekly.down"), abs(pct)) }
            return nil
        }()
        NotificationManager.scheduleWeeklyRecap(
            expensesFormatted: CurrencyManager.shared.formatted(thisWeek, currency: preferred),
            deltaText: weeklyDelta
        )

        // ── Monthly figures (summary + overspend) ──────────────────────
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now
        var monthExpense = 0.0
        var monthIncome  = 0.0
        var perCategory: [TxCategory: Double] = [:]
        for tx in txs where tx.date >= monthStart && tx.date <= now {
            let v = converted(tx)
            switch tx.txSubtype {
            case .transfer: continue
            case .refund:
                monthExpense -= abs(v)
                perCategory[tx.category, default: 0] -= abs(v)
            case .normal:
                if v < 0 {
                    monthExpense += abs(v)
                    perCategory[tx.category, default: 0] += abs(v)
                } else {
                    monthIncome += v
                }
            }
        }
        if monthExpense < 0 { monthExpense = 0 }

        let topCategory = perCategory
            .filter { $0.value > 0 }
            .max { $0.value < $1.value }?
            .key.displayLabel

        NotificationManager.scheduleMonthlySummary(
            incomeFormatted:  CurrencyManager.shared.formatted(monthIncome,  currency: preferred),
            expenseFormatted: CurrencyManager.shared.formatted(monthExpense, currency: preferred),
            topCategory: topCategory
        )

        // ── Inactivity nudge ───────────────────────────────────────────
        let lastTxDate = txs.map(\.date).max()
        NotificationManager.scheduleInactivityNudge(lastTxDate: lastTxDate)

        // ── Overspend push ─────────────────────────────────────────────
        let topCatEntry = perCategory.filter { $0.value > 0 }.max { $0.value < $1.value }
        NotificationManager.checkOverspendPush(
            income: monthIncome, expense: monthExpense, currencyCode: preferred,
            topCategory: topCatEntry?.key.displayLabel,
            topCategoryAmount: topCatEntry?.value ?? 0
        )

        // ── Debt due-date reminders ────────────────────────────────────
        scheduleDebtReminders(context: context, preferred: preferred, cal: cal, now: now)

        // ── Smart Budget per-group over-budget alert ───────────────────
        checkSmartBudgetAlerts(txs: txs, context: context, preferred: preferred)
    }

    /// Warn a few days before each active debt's due date. `postDebtReminder`
    /// has existed since the debt tracker shipped but was never called, so
    /// instalments could quietly fall past due with no nudge at all.
    ///
    /// Debt tracking is Royal-only, so this follows the same entitlement.
    private static func scheduleDebtReminders(context: ModelContext, preferred: String,
                                              cal: Calendar, now: Date) {
        guard PremiumManager.shared.canAccess(.smartDebt) else { return }
        let debts: [DebtRecord] = (try? context.fetch(FetchDescriptor<DebtRecord>())) ?? []
        let cm = CurrencyManager.shared

        for debt in debts where debt.isActive && debt.currentBalance > 0 && !debt.manuallyClosed {
            let day = min(max(debt.dueDayOfMonth, 1), 28)
            var comps = cal.dateComponents([.year, .month], from: now)
            comps.day = day
            var due = cal.safeDate(from: comps)
            // Already past this month → aim at next month's due date.
            if due < cal.startOfDay(for: now) {
                due = cal.safeDate(byAdding: .month, value: 1, to: due)
            }
            let daysUntil = cal.dateComponents([.day], from: cal.startOfDay(for: now),
                                               to: cal.startOfDay(for: due)).day ?? 99
            // Three days out is early enough to move money, late enough not to
            // be forgotten.
            guard (0...3).contains(daysUntil) else { continue }

            // Once per debt per month.
            let key = "debt_due_\(debt.id.uuidString)_\(cal.component(.year, from: due))_\(cal.component(.month, from: due))"
            guard !UserDefaults.standard.bool(forKey: key) else { continue }
            UserDefaults.standard.set(true, forKey: key)

            let minPay = cm.convert(debt.effectiveMinimumPayment, from: debt.currency, to: preferred)
            let balance = cm.convert(debt.currentBalance, from: debt.currency, to: preferred)
            let advice: String = {
                if debt.annualInterestRate > 0 {
                    // Interest-bearing: the cost of being late is concrete.
                    let monthlyCost = balance * (debt.annualInterestRate / 100 / 12)
                    return String(format: loc("notif.debt_advice_interest"),
                                  cm.formatted(minPay, currency: preferred),
                                  Int(debt.annualInterestRate),
                                  cm.formatted(monthlyCost, currency: preferred))
                }
                let months = minPay > 0 ? Int(ceil(balance / minPay)) : 0
                return String(format: loc("notif.debt_advice_zero"),
                              cm.formatted(minPay, currency: preferred), months)
            }()

            NotificationManager.shared.postDebtReminder(
                name: debt.name,
                amount: cm.formatted(minPay, currency: preferred),
                dueDay: day,
                advice: advice)
        }
    }

    /// Fire an over-budget alert for any Smart Budget group that has exceeded
    /// its target this pay cycle. Mirrors the in-app Smart Budget screen: income
    /// comes from the salary schedule and the window is pay-cycle-aware, so an
    /// alert lines up with the red "over budget" banner the user already sees.
    /// Deduped once per cycle per group inside `postBudgetGroupAlert`.
    private static func checkSmartBudgetAlerts(txs: [TxRecord], context: ModelContext, preferred: String) {
        let mgr = SmartBudgetManager.shared
        // `hasActiveBudget`, NOT the raw `isEnabled` toggle. `isEnabled` is a
        // preference persisted in UserDefaults that deliberately survives
        // logout and subscription changes — so a user who set it while Royal
        // kept receiving Royal-only budget alerts after their subscription
        // lapsed. This is exactly the rule `hasActiveBudget`'s own doc comment
        // warns about; it was being violated here.
        guard mgr.hasActiveBudget else { return }
        let cal = Calendar.current
        let cm  = CurrencyManager.shared

        // Pay-cycle window + income from active salary schedules.
        let salaries: [SalarySchedule] = (try? context.fetch(FetchDescriptor<SalarySchedule>())) ?? []
        let budgetConfigs: [CardBudgetConfig] = (try? context.fetch(FetchDescriptor<CardBudgetConfig>())) ?? []
        let active = salaries.filter { $0.isActive }
        let periodStart: Date = {
            if let day = active.first?.dayOfMonth { return StatPeriod.payCycleRange(payDay: day).start }
            return cal.date(from: cal.dateComponents([.year, .month], from: Date())) ?? Date()
        }()

        // Stated salary income first (the budget's signal even before payday);
        // else income transactions logged within the window.
        var income = active.reduce(0.0) { $0 + cm.convert($1.amount, from: $1.currency, to: preferred) }
        if income <= 0 {
            income = txs.filter { $0.date >= periodStart && $0.amount > 0 && $0.txSubtype != .transfer }
                .reduce(0.0) { $0 + cm.convert($1.amount, from: ($1.currency.isEmpty ? preferred : $1.currency), to: preferred) }
        }
        guard income > 0 else { return }

        let windowTx = txs.filter { $0.date >= periodStart && $0.amount < 0 && $0.txSubtype != .transfer }
        let cycleKey = ISO8601DateFormatter.dayString(from: periodStart)

        // Only spending groups can be "over budget". Invest & Debt being UNDER
        // its allocation is a savings shortfall, not an overspend — not alerted.
        for group in [BudgetGroup.daily, .lifestyle] {
            // periodStart required — otherwise spent() clips the cycle back to
            // the calendar month and the alert misses the pre-1st spending.
            let spent = mgr.spent(in: group, transactions: windowTx, targetCurrency: preferred,
                                  periodStart: periodStart)
            // Per-card ratios, not the globals: a user whose budget follows one
            // card has an override, and alerting against the global target
            // fired warnings that contradicted the budget screen they'd open.
            let ratio = mgr.ratio(for: group, cardID: mgr.budgetCardID, configs: budgetConfigs)
            let limit = income * ratio
            guard limit > 0, spent > limit else { continue }   // strictly over target
            let over = spent - limit

            // Where the remedy can come from: the OTHER spending group's unused
            // headroom. Naming a real number turns "you're over" into a choice
            // the user can actually make.
            let otherGroup: BudgetGroup = (group == .daily) ? .lifestyle : .daily
            let otherRatio = mgr.ratio(for: otherGroup, cardID: mgr.budgetCardID, configs: budgetConfigs)
            let otherLimit = income * otherRatio
            let otherSpent = mgr.spent(in: otherGroup, transactions: windowTx,
                                       targetCurrency: preferred, periodStart: periodStart)
            let otherHeadroom = max(otherLimit - otherSpent, 0)

            let daysLeft = max((cal.dateComponents([.day], from: Date(),
                                                   to: cal.date(byAdding: .month, value: 1, to: periodStart) ?? Date()).day ?? 0), 0)

            let advice: String = {
                if otherHeadroom >= over {
                    // A shift covers it — no new money needed, just a decision.
                    return String(format: loc("notif.budget_advice_shift"),
                                  cm.formatted(over, currency: preferred),
                                  otherGroup.label.lowercased(),
                                  cm.formatted(otherHeadroom, currency: preferred),
                                  daysLeft)
                }
                // Nothing spare anywhere: the plan itself is the problem.
                return String(format: loc("notif.budget_advice_replan"),
                              cm.formatted(over, currency: preferred), daysLeft)
            }()

            NotificationManager.postBudgetGroupAlert(
                group: group.label, overAmount: over, limit: limit,
                currency: preferred, cycleKey: cycleKey, advice: advice)
        }
    }
}

// MARK: - Contact Admin Sheet
