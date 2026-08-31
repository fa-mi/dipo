import SwiftUI
import UserNotifications

// MARK: - Notification Preferences
//
// Which reminders DiPo is allowed to send. Every one defaults ON, because a
// finance app that says nothing is not doing its job — but the user gets to
// decide which of them are useful to THEM.
//
// Why granular rather than one master switch: the alerts differ enormously in
// value. A debt due-date warning prevents a late fee. A budget alert tells you
// something you may already know from the Home screen you just looked at. One
// switch forces the user to give up the first to escape the second, so the
// realistic outcome is that they disable everything and DiPo goes silent about
// things that actually cost money.
//
// Stored in `UserDefaults.standard` and deliberately NOT wiped on sign-out:
// these are how a PERSON wants to be interrupted on THIS device, not part of an
// account's financial data. A different user signing in inherits nothing
// sensitive — only a set of "don't nag me about X" choices they can change.
@Observable
@MainActor
final class NotificationPreferences {
    static let shared = NotificationPreferences()

    enum Kind: String, CaseIterable, Identifiable {
        case budget      // over-budget group alerts + spending-over-income
        case payday      // salary reminders
        case debt        // due-date warnings
        case summary     // weekly recap + monthly summary
        case inactivity  // "you haven't logged anything in 3 days"
        case backup      // "your data hasn't been backed up in a while"

        var id: String { rawValue }

        var titleKey: String {
            switch self {
            case .budget:     return "notifpref.budget"
            case .payday:     return "notifpref.payday"
            case .debt:       return "notifpref.debt"
            case .summary:    return "notifpref.summary"
            case .inactivity: return "notifpref.inactivity"
            case .backup:     return "notifpref.backup"
            }
        }
        var subtitleKey: String {
            switch self {
            case .budget:     return "notifpref.budget_sub"
            case .payday:     return "notifpref.payday_sub"
            case .debt:       return "notifpref.debt_sub"
            case .summary:    return "notifpref.summary_sub"
            case .inactivity: return "notifpref.inactivity_sub"
            case .backup:     return "notifpref.backup_sub"
            }
        }
        var icon: String {
            switch self {
            case .budget:     return "chart.pie.fill"
            case .payday:     return "banknote.fill"
            case .debt:       return "creditcard.fill"
            case .summary:    return "calendar"
            case .inactivity: return "bell.badge"
            case .backup:     return "externaldrive.fill.badge.icloud"
            }
        }
        var tint: Color {
            switch self {
            case .budget:     return AppTheme.red
            case .payday:     return AppTheme.accent
            case .debt:       return AppTheme.orange
            case .summary:    return AppTheme.blue
            case .inactivity: return AppTheme.purple
            case .backup:     return AppTheme.teal
            }
        }
        fileprivate var storageKey: String { "notifpref_\(rawValue)" }
    }

    private init() {
        // Absent key means "never chosen" → on. Registering defaults rather
        // than reading `bool(forKey:)` raw, because that returns false for a
        // missing key and would ship the app silent.
        UserDefaults.standard.register(
            defaults: Dictionary(uniqueKeysWithValues: Kind.allCases.map { ($0.storageKey, true) })
        )
    }

    func isEnabled(_ kind: Kind) -> Bool {
        UserDefaults.standard.bool(forKey: kind.storageKey)
    }

    func setEnabled(_ kind: Kind, _ on: Bool) {
        UserDefaults.standard.set(on, forKey: kind.storageKey)
        // Turning a category off should silence it NOW, not at the next
        // scheduling pass — anything already queued with iOS must go.
        if !on { Self.cancelPending(for: kind) }
    }

    /// Identifier prefixes each category owns, so switching it off can drop the
    /// requests iOS is already holding.
    private static func cancelPending(for kind: Kind) {
        let prefixes: [String]
        switch kind {
        case .budget:     prefixes = ["smart_budget_alert", "smart_overspend"]
        case .payday:     prefixes = ["salary_"]
        case .debt:       prefixes = ["debt_due_"]
        case .summary:    prefixes = ["smart_weekly", "smart_monthly"]
        case .inactivity: prefixes = ["smart_inactivity"]
        case .backup:     prefixes = ["backup_reminder"]
        }
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            let doomed = requests.map(\.identifier)
                .filter { id in prefixes.contains { id.hasPrefix($0) } }
            guard !doomed.isEmpty else { return }
            center.removePendingNotificationRequests(withIdentifiers: doomed)
        }
    }
}
