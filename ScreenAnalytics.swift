import SwiftUI
import FirebaseAnalytics
import FirebaseFirestore

// MARK: - Screen analytics
//
// Which screens get opened, and nothing else.
//
// This is a personal-finance app, so the boundary matters more than the
// feature. What leaves the device is a screen name from a FIXED list defined in
// this file — never an amount, a merchant, a card, a category, a balance, a
// goal, a date, or anything typed by the user. There is no event that carries a
// value, because there is no parameter to put one in.
//
// The list being an enum is the enforcement, not a convention: a caller cannot
// pass a string, so no future screen can accidentally log "Transaction: kopi
// 25000" by interpolating something into a name.
//
// It is off unless the BACKEND says otherwise — `app_config/analytics`, the
// same collection maintenance mode already uses. Not a switch in Settings: the
// person holding the phone is usually not the person running the product, so a
// toggle there asks them a question that was never theirs. Every failure mode
// resolves to off, because an unreachable server is not consent.
enum Screen: String {
    case home, statistics, wallet, profile
    case addTransaction, transactionDetail
    case smartBudget, smartBudgetSettings, budgetRecommendation
    case spendingAudit, obligations, debts, receivables, planner
    case salarySchedule, recurring, savingsGoals, unitySavings
    case cardForm, transfer, mainCardGate
    case askDiPo, receiptScan, backup, webSync, support, paywall
}

@Observable
final class ScreenAnalytics {
    static let shared = ScreenAnalytics()

    /// Cache of the last value the backend sent, so the first screens after a
    /// cold launch are not lost to a network round trip — and so the app still
    /// knows the answer offline.
    private static let cacheKey = "analytics_screen_remote"

    /// Controlled from `app_config/analytics`, not from a switch in Settings.
    ///
    /// This began as a user toggle in Profile and that was the wrong shape: the
    /// person holding the phone is usually not the person who runs the product,
    /// so the setting sat in their way asking a question that was never theirs
    /// to answer. It is an operator's decision about the product, so it lives
    /// where the operator is.
    ///
    /// Still defaults to OFF and stays off until the backend explicitly says
    /// otherwise. A missing document, a failed read, a first launch — every one
    /// of those means no collection, because "we could not reach the server" is
    /// not consent.
    private(set) var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.cacheKey)
            Analytics.setAnalyticsCollectionEnabled(isEnabled)
        }
    }

    private var listener: ListenerRegistration?

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.cacheKey)
        Analytics.setAnalyticsCollectionEnabled(isEnabled)
    }

    /// Mirrors `app_config/analytics` in real time, the same way maintenance
    /// mode already does. Safe to call repeatedly.
    func startListening() {
        listener?.remove()
        listener = Firestore.firestore().collection("app_config").document("analytics")
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self else { return }
                // An error is not a "yes". Leave the cached answer alone rather
                // than defaulting to on because a read failed.
                guard error == nil else { return }
                let on = (snapshot?.data()?["screenTracking"] as? Bool) ?? false
                Task { @MainActor in self.isEnabled = on }
            }
    }

    /// Records that a screen was opened.
    ///
    /// Uses Firebase's own `screen_view`, so the console's built-in screen
    /// reports work without a custom dashboard. `screen_class` is deliberately
    /// the same raw name rather than the Swift type: type names change when
    /// views are refactored and would split one screen's history in two.
    func opened(_ screen: Screen) {
        guard isEnabled else { return }
        Analytics.logEvent(AnalyticsEventScreenView, parameters: [
            AnalyticsParameterScreenName: screen.rawValue,
            AnalyticsParameterScreenClass: screen.rawValue,
        ])
        bumpCounter(screen)
    }

    /// A running total per screen, in Firestore.
    ///
    /// This is a duplicate of what Firebase already records, and it exists for
    /// one reason: Analytics data lives in the Firebase console, not in
    /// Firestore, so the DiPo admin page — a static site reading Firestore —
    /// cannot see it. Reading it properly would need a BigQuery export or the
    /// Analytics Data API with a service account, neither of which belongs in a
    /// client-side page.
    ///
    /// AGGREGATE ONLY: one document per screen, a count and a timestamp, no
    /// user id anywhere. It answers "which screens get used" and cannot answer
    /// "what did this person do", which is the only version of this worth
    /// storing in an app about someone's money.
    private func bumpCounter(_ screen: Screen) {
        Firestore.firestore()
            .collection("analytics_screens").document(screen.rawValue)
            .setData([
                "count": FieldValue.increment(Int64(1)),
                "lastOpened": FieldValue.serverTimestamp(),
            ], merge: true)
    }
}

extension View {
    /// Marks a screen for usage counting. The ONLY way to log from a view, and
    /// it takes an enum case — there is no overload accepting a string.
    func trackScreen(_ screen: Screen) -> some View {
        onAppear { ScreenAnalytics.shared.opened(screen) }
    }
}
