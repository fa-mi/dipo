import SwiftUI
import RevenueCat
import SwiftData
import UserNotifications
import WidgetKit

// MARK: - Widget Data Bridge
//
// The iOS Home Screen widget (`DiPoMonthlyExpensesWidget`) runs in a
// separate process and can't read SwiftData directly. We mirror the few
// numbers it needs (this month's expenses + income, currency, pretty month
// label) into an App Group-shared `UserDefaults`, then poke `WidgetKit`
// so the widget redraws.
//
// Triggers are intentionally conservative — refresh on app launch, on
// foreground, and on `liveCards` / `liveTxs` count changes (see below).
// Over-refreshing burns the iOS widget budget without user benefit.
//
// The matching keys + App Group ID live in `DiPoWidgetSharedKeys.swift`
// inside the widget target. Changing one without the other silently
// breaks the bridge.

@MainActor
enum WidgetDataSync {
    /// Must match the App Group enabled on BOTH the app target and the
    /// widget target.
    static let appGroupID = "group.com.fahmiaquinas.DiPo"

    enum Key {
        // Always-on numbers (free + Royal users alike).
        static let monthlyExpenses          = "widget.monthlyExpenses"
        static let monthlyExpensesFormatted = "widget.monthlyExpensesFormatted"
        static let monthlyIncome            = "widget.monthlyIncome"
        static let monthlyIncomeFormatted   = "widget.monthlyIncomeFormatted"
        static let currency                 = "widget.currency"
        static let monthLabel               = "widget.monthLabel"
        static let lastUpdated              = "widget.lastUpdated"

        // Royal-only insights. Written for everyone but read only when
        // `isRoyal` is true — keeps the bridge simple while letting us
        // unlock UI in the widget without another refresh hop.
        static let isRoyal                  = "widget.isRoyal"
        static let topCategoryLabel         = "widget.topCategoryLabel"
        static let topCategoryFormatted     = "widget.topCategoryFormatted"
        static let topCategoryPercent       = "widget.topCategoryPercent"
        static let weeklyAvgFormatted       = "widget.weeklyAvgFormatted"

        // Localized labels — written by the app so the widget doesn't need
        // its own LanguageManager. Mirrors current `LanguageManager.shared`
        // language; updated on every `refresh`.
        static let labelExpenses            = "widget.label.expenses"
        static let labelIncome              = "widget.label.income"
        static let labelQuickAdd            = "widget.label.quickAdd"
        static let labelTopCategory         = "widget.label.topCategory"
        static let labelWeeklyAvg           = "widget.label.weeklyAvg"
    }

    /// Returns nil if the App Group capability isn't enabled yet — fail
    /// silent rather than crash, since the host app should still work
    /// without the widget bridge.
    static var shared: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    /// Recompute monthly totals from SwiftData, write pre-formatted strings
    /// to the shared store, and tell WidgetKit to redraw.
    static func refresh(context: ModelContext) {
        guard let store = shared else { return }

        let cal = Calendar.current
        let now = Date()
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now
        let txs: [TxRecord] = (try? context.fetch(FetchDescriptor<TxRecord>())) ?? []

        let preferred = CurrencyManager.shared.preferredCurrency
        var expenses: Double = 0
        var income: Double   = 0
        // Per-category running totals for Royal users' "top spend" insight.
        var perCategory: [TxCategory: Double] = [:]

        // Mirror StatisticsView's subtype-aware logic so widget numbers
        // match what the user sees in the in-app Stats screen.
        for tx in txs where tx.date >= monthStart && tx.date <= now {
            let txCurrency = tx.currency.isEmpty ? preferred : tx.currency
            let converted  = CurrencyManager.shared.convert(tx.amount, from: txCurrency, to: preferred)
            switch tx.txSubtype {
            case .transfer:
                continue
            case .refund:
                expenses -= abs(converted)
                perCategory[tx.category, default: 0] -= abs(converted)
            case .normal:
                if converted < 0 {
                    expenses += abs(converted)
                    perCategory[tx.category, default: 0] += abs(converted)
                } else {
                    income += converted
                }
            }
        }
        if expenses < 0 { expenses = 0 }

        let expensesFormatted = CurrencyManager.shared.formatted(expenses, currency: preferred)
        let incomeFormatted   = CurrencyManager.shared.formatted(income,   currency: preferred)

        // Localized month label like "Mei 2026" — follows in-app language.
        let monthFmt = DateFormatter()
        monthFmt.locale = LanguageManager.shared.currentLocale
        monthFmt.dateFormat = DateFormatter.dateFormat(
            fromTemplate: "MMMMyyyy",
            options: 0,
            locale: monthFmt.locale
        )
        let monthLabel = monthFmt.string(from: monthStart)

        // ── Royal-only insights ────────────────────────────────────────
        // Top category by spend in the current month + its % share.
        // Plus a weekly average ("how much do I burn per week") which
        // mirrors `StatisticsView.weeklyAverage`. These are gated in the
        // widget UI by `isRoyal`, but we always compute + write them so
        // the moment a user upgrades, the widget unlocks on the next
        // refresh without needing schema changes here.
        let isRoyal = (PremiumManager.shared.plan == .royal)
        let topEntry = perCategory.filter { $0.value > 0 }.max { $0.value < $1.value }
        let topCategoryLabel     = topEntry?.key.displayLabel ?? ""
        let topCategoryFormatted = topEntry.map {
            CurrencyManager.shared.formatted($0.value, currency: preferred)
        } ?? ""
        let topCategoryPercent: Int = {
            guard let top = topEntry?.value, expenses > 0 else { return 0 }
            return Int((top / expenses * 100).rounded())
        }()

        // Weekly avg = total expenses ÷ (days elapsed this month ÷ 7).
        // Same shape as StatisticsView so numbers agree across surfaces.
        let daysElapsed = max(cal.dateComponents([.day], from: monthStart, to: now).day ?? 1, 1)
        let weeks       = max(Double(daysElapsed) / 7.0, 0.1)
        let weeklyAvg   = expenses / weeks
        let weeklyAvgFormatted = CurrencyManager.shared.formatted(weeklyAvg, currency: preferred)

        // ── Localized labels ───────────────────────────────────────────
        // The widget can't import LanguageManager (separate process), so
        // we pre-resolve all UI strings here. They get updated on every
        // refresh which means switching language in-app propagates to the
        // widget the next time `refresh` runs (foreground / launch / tx
        // change). Worst case: 1-hour fallback timer eventually picks it up.
        let labelExpenses    = loc("widget.label.expenses")
        let labelIncome      = loc("widget.label.income")
        let labelQuickAdd    = loc("widget.label.quickAdd")
        let labelTopCategory = loc("widget.label.topCategory")
        let labelWeeklyAvg   = loc("widget.label.weeklyAvg")

        // ── Write everything ───────────────────────────────────────────
        store.set(expenses,             forKey: Key.monthlyExpenses)
        store.set(expensesFormatted,    forKey: Key.monthlyExpensesFormatted)
        store.set(income,               forKey: Key.monthlyIncome)
        store.set(incomeFormatted,      forKey: Key.monthlyIncomeFormatted)
        store.set(preferred,            forKey: Key.currency)
        store.set(monthLabel,           forKey: Key.monthLabel)
        store.set(now,                  forKey: Key.lastUpdated)

        store.set(isRoyal,              forKey: Key.isRoyal)
        store.set(topCategoryLabel,     forKey: Key.topCategoryLabel)
        store.set(topCategoryFormatted, forKey: Key.topCategoryFormatted)
        store.set(topCategoryPercent,   forKey: Key.topCategoryPercent)
        store.set(weeklyAvgFormatted,   forKey: Key.weeklyAvgFormatted)

        store.set(labelExpenses,    forKey: Key.labelExpenses)
        store.set(labelIncome,      forKey: Key.labelIncome)
        store.set(labelQuickAdd,    forKey: Key.labelQuickAdd)
        store.set(labelTopCategory, forKey: Key.labelTopCategory)
        store.set(labelWeeklyAvg,   forKey: Key.labelWeeklyAvg)

        WidgetCenter.shared.reloadAllTimelines()
    }
}

// MARK: - Root View
// @Query here means ANY change to BankCard in SwiftData
// instantly propagates to appVM.cards across the whole app.

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase)   private var scenePhase

    // This @Query is the live observer — SwiftData notifies it
    // the moment any card is inserted, updated, or deleted
    @Query(sort: \BankCard.sortOrder) private var liveCards: [BankCard]

    // Watching transactions directly (not just cards) is what lets the
    // widget bridge refresh when a tx is added/edited/deleted — `liveCards`
    // doesn't fire on relationship-only changes, so we'd otherwise miss
    // those events. We only need the count for change detection, not the
    // rows themselves, so the read cost is trivial.
    @Query private var liveTxs: [TxRecord]

    @State private var appVM  = AppViewModel()
    @State private var authVM = AuthViewModel()

    var body: some View {
        ZStack {
            AppTheme.bg.ignoresSafeArea()

            switch authVM.authState {
            case .splash:
                SplashView().transition(.opacity)
            case .setup:
                SetupView(authVM: authVM)
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .opacity))
            case .biometric:
                BiometricGateView(authVM: authVM)
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .scale(scale: 1.05).combined(with: .opacity)))
            case .authenticated:
                MainTabView(vm: appVM, authVM: authVM)
                    .transition(.asymmetric(
                        insertion: .opacity,
                        removal: .scale(scale: 0.95).combined(with: .opacity)))
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.82), value: authVM.authState)
        .overlay { NoInternetOverlay() }      // full-screen offline view
        .overlay(alignment: .top) { ReconnectedToast() }  // brief "Back online" toast

        // KEY: whenever SwiftData adds/removes/edits any BankCard,
        // liveCards updates automatically → sync straight into appVM
        .onChange(of: liveCards) { _, newCards in
            appVM.cards = newCards
            if appVM.selectedCardIndex >= newCards.count {
                appVM.selectedCardIndex = max(0, newCards.count - 1)
            }
            // Re-check expiry whenever cards are added/edited/deleted
            Task { @MainActor in
                NotificationManager.scheduleCardExpiryReminders(for: newCards)
            }
            // Card changes can affect widget totals (e.g. card deletion
            // cascades to its transactions). Refresh the bridge here too.
            WidgetDataSync.refresh(context: context)
        }
        // Refresh widget whenever a tx is added/edited/deleted. We key on
        // `count` so we don't churn on every field edit — the widget only
        // cares about totals, not individual row mutations.
        .onChange(of: liveTxs.count) { _, _ in
            WidgetDataSync.refresh(context: context)
            // A new/removed transaction shifts the weekly/monthly totals
            // and resets the inactivity clock — reschedule smart reminders.
            NotificationScheduler.refresh(context: context)
        }

        // ✅ Restart the Firestore replies listener whenever userID changes.
        // onAppear only fires once — if the user is a guest on first launch and
        // logs in later, the listener would never start without this reactive hook.
        .onChange(of: UserSession.shared.userID) { _, newID in
            if let newID {
                // Privacy guard: if a DIFFERENT user just signed in on this
                // device, wipe the previous user's local SwiftData + caches
                // BEFORE any UI binds to the data. Same user re-signing-in
                // doesn't trigger a wipe (UserSwitchDetector compares IDs).
                // This must come before the notification listener below so the
                // notifications queue is also cleared.
                UserSwitchDetector.handleSignIn(userID: newID, context: context)
                // Admin broadcast + ticket-reply listener — replays anything
                // the admin sent (including support replies, which the admin
                // panel writes to user_notifications) straight into the bell.
                // NOTE: we intentionally no longer run a separate
                // `startListeningForReplies()` here. That older path posted its
                // OWN local push + bell entry for ticket replies, which — now
                // that the admin panel also fires an FCM push and writes a
                // user_notifications doc — produced TWO banners and TWO bell
                // rows per reply. The single dual-channel path below (FCM
                // banner + this Firestore-backed bell) is the source of truth.
                FirebaseSupportService.shared.startListeningForAdminNotifications()
                // Register this device's push token under the freshly
                // signed-in user so the admin panel can target them.
                Task { await FirebaseSupportService.shared.registerCurrentDeviceToken() }
            } else {
                FirebaseSupportService.shared.stopListening()
            }
        }

        .onChange(of: scenePhase) { _, newPhase in
            authVM.handleScenePhase(newPhase)
            if newPhase == .active {
                appVM.cards = liveCards
                SalaryCreditEngine.processIfNeeded(context: context)
                // Re-check entitlement every time app comes to foreground.
                // This catches Royal activation after the deferred billing date
                // without needing a backend webhook or push notification.
                PremiumManager.shared.checkActiveSubscription()
                // Foregrounding is a cheap opportunity to recompute widget
                // totals — handles month rollover, FX rate refresh, and any
                // background-modified data we missed.
                WidgetDataSync.refresh(context: context)
                // Re-bake the smart reminders with fresh numbers too. Their
                // one-shot notifications carry live figures, so the more
                // recently they're rescheduled, the more accurate the recap.
                NotificationScheduler.refresh(context: context)
            }
        }

        .onAppear {
            appVM.cards = liveCards
            UserSession.shared.checkAppleCredentialState { _ in }
            // Recover email for users who signed in before email capture was
            // fixed — so support/broadcast emails can reach them. Runs before
            // registerCurrentDeviceToken below so the email lands in device_tokens.
            UserSession.shared.backfillEmailFromFirebaseIfNeeded()
            authVM.bootstrap()
            HapticManager.shared.prepare()
            CurrencyManager.shared.fetchRate()
            SalaryCreditEngine.processIfNeeded(context: context)
            // First write of widget data so the Home Screen shows real
            // numbers instead of the gallery placeholder on first launch.
            WidgetDataSync.refresh(context: context)
            // Schedule the smart reminders (weekly recap, monthly summary,
            // inactivity nudge, overspend alert) on launch too.
            NotificationScheduler.refresh(context: context)
            // Check card expiry on every launch
            NotificationManager.scheduleCardExpiryReminders(for: liveCards)
            // Single, authoritative RevenueCat configure — must stay here (post-SwiftUI init).
            // Never call Purchases.configure() a second time anywhere else in the app.
            // Previously a duplicate call existed in App.init() with a test key, which caused
            // an EXC_BREAKPOINT crash (SDK assertionFailure) within ~3 ms of launch.
            let rcKey = Bundle.main.object(forInfoDictionaryKey: "REVENUECAT_API_KEY") as? String ?? ""
            Purchases.configure(withAPIKey: rcKey)
            PremiumManager.shared.checkActiveSubscription()
            // Admin broadcast + ticket-reply listener — on launch its initial
            // snapshot replays any admin notification (broadcasts AND support
            // replies) written to user_notifications while the app was closed,
            // guaranteeing it lands in the in-app bell. The matching FCM push
            // (sent by the admin panel) handles the lock-screen banner. See the
            // userID `.onChange` above for why the older startListeningForReplies
            // path was removed (it double-fired notifications).
            FirebaseSupportService.shared.startListeningForAdminNotifications()
            // Register this device's push token on every launch too — the
            // userID `.onChange` above does NOT fire for users restored
            // from Keychain at startup, so returning users would otherwise
            // never get into `device_tokens` and admin push couldn't reach
            // them.
            Task { await FirebaseSupportService.shared.registerCurrentDeviceToken() }
            // ✅ Pre-fetch Indonesian public holidays for this year + next year
            // from api-harilibur.vercel.app (free, no auth). Cached for offline use.
            IndonesianHolidayService.shared.prefetch()
            // ✅ Register for remote (APNs/FCM) push notifications.
            // This is what allows notifications even when the app is fully closed.
            NotificationManager.registerForRemotePushNotifications()
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                if granted, UserDefaults.standard.bool(forKey: "daily_reminder_on") {
                    NotificationManager.scheduleDailyReminder()
                }
            }
        }
    }
}
