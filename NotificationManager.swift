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

    /// True when this notification is an admin support-ticket reply.
    var isTicketReply: Bool { kind == "ticket_reply" }

    init(icon: String, iconColorHex: String, title: String, body: String,
         time: String, isUrgent: Bool = false,
         imageUrl: String? = nil, linkUrl: String? = nil,
         kind: String? = nil) {
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

    func postPayday(label: String, amount: String, daysUntil: Int) {
        switch daysUntil {
        case 0:
            post(AppNotificationItem(icon: "banknote.fill", iconColorHex: "#1DB87A",
                title: loc("notif.payday.today_title"),
                body:  String(format: loc("notif.payday.today_body"), label, amount),
                time:  loc("notif.time.today"), isUrgent: true))
        case 1:
            post(AppNotificationItem(icon: "clock.fill", iconColorHex: "#FB923C",
                title: loc("notif.payday.tomorrow_title"),
                body:  String(format: loc("notif.payday.tomorrow_body"), label),
                time:  loc("notif.time.tomorrow"), isUrgent: true))
        default:
            post(AppNotificationItem(icon: "calendar.badge.clock", iconColorHex: "#38BDF8",
                title: String(format: loc("notif.payday.future_title"), daysUntil),
                body:  String(format: loc("notif.payday.future_body"), label),
                time:  String(format: loc("notif.time.in_days"), daysUntil)))
        }
    }

    func postBudgetAlert(group: String, pct: Int) {
        post(AppNotificationItem(icon: "exclamationmark.triangle.fill", iconColorHex: "#FF6B6B",
            title: String(format: loc("notif.budget_alert_title"), group),
            body:  String(format: loc("notif.budget_alert_body"), pct, group.lowercased()),
            time:  loc("notif.time.now"), isUrgent: true))
    }

    func postDebtReminder(name: String, amount: String, dueDay: Int) {
        post(AppNotificationItem(icon: "creditcard.trianglebadge.exclamationmark", iconColorHex: "#FF6B6B",
            title: loc("notif.debt_due_title"),
            body:  String(format: loc("notif.debt_due_body"), name, amount, dueDay),
            time:  loc("notif.time.upcoming"), isUrgent: true))
    }

    func postSavingsGoalReached(name: String, emoji: String) {
        post(AppNotificationItem(icon: "star.fill", iconColorHex: "#FB923C",
            title: String(format: loc("notif.goal_reached_title"), emoji),
            body:  String(format: loc("notif.goal_reached_body"), name),
            time:  loc("notif.time.now"), isUrgent: true))
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
    }

    func markRead(_ id: UUID) {
        if let idx = items.firstIndex(where: { $0.id == id }) {
            items[idx].isRead = true
            save()
        }
    }

    func clearAll() {
        withAnimation { items = [] }
        save()
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
    static func checkOverspendPush(income: Double, expense: Double, currencyCode: String) {
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
        NotificationManager.shared.post(AppNotificationItem(
            icon: "exclamationmark.triangle.fill", iconColorHex: "#FF5B5B",
            title: loc("notif.overspend.title"),
            body:  String(format: loc("notif.overspend.body"), overBy),
            time:  loc("notif.time.now"), isUrgent: true
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
        NotificationManager.checkOverspendPush(
            income: monthIncome, expense: monthExpense, currencyCode: preferred
        )
    }
}

// MARK: - Contact Admin Sheet
