import Foundation
import SwiftData
import UserNotifications

// MARK: - Deleting everything a person kept
//
// "Reset All Data" and the wipe when a different account signs in on the
// same phone each kept their own list of models to delete, and both lists
// stopped growing long before the app did: money lent out, card
// instalments, investments, assets, spend-free days, the daily totals cache
// and the review queue — which holds the original text of bank notifications
// and SMS — all stayed behind for whoever came next. The list is now the
// schema itself, so a model added later is deleted without anyone
// remembering to add it here.

enum LocalDataWipe {

    /// Deletes every record of every model the app keeps, then the copies
    /// that outlive them: the daily totals held in memory, and pushes still
    /// waiting to tell someone about a record that is gone.
    static func deleteAllRecords(in context: ModelContext) {
        for model in DiPoSchemaCurrent.models {
            deleteAll(model, in: context)
        }
        try? context.save()
        // Built from what is left, which is nothing: the totals Home and
        // Statistics read from memory empty with the store.
        RollupStore.shared.rebuild(context: context)
        clearRemindersAboutRecords()
        HeldWantReminders.scheduleAll(wants: [])
    }

    private static func deleteAll<T: PersistentModel>(_ model: T.Type, in context: ModelContext) {
        try? context.delete(model: model)
    }

    /// Pending pushes that speak about the records: a debt's due date, a
    /// card's expiry, a salary, an asset's tax, a held want, and the alerts
    /// and summaries drawn from the ledger. They go with the data; the next
    /// scheduling pass sets up whatever still applies. The daily check-in
    /// says nothing about anyone's money and stays.
    static let reminderPrefixes = ["smart_", "debt_due_", "card_expiry_", "salary_",
                                   AssetTaxReminders.idPrefix, HeldWantReminders.idPrefix]

    /// Notifications already shown and still sitting in Notification Center.
    /// Used when a different person signs in: what was written to the last
    /// one is not for them.
    static func clearDeliveredNotifications() {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    private static func clearRemindersAboutRecords() {
        let prefixes = reminderPrefixes
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            let doomed = requests.map(\.identifier).filter { id in prefixes.contains { id.hasPrefix($0) } }
            guard !doomed.isEmpty else { return }
            center.removePendingNotificationRequests(withIdentifiers: doomed)
        }
    }
}
