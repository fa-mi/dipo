import AppIntents
import Foundation
import SwiftData

// MARK: - Log a payment from another app's notification
//
// Built once by the user, in Shortcuts: "when I receive a notification from
// Livin', GoPay, DANA…, run Log from a Notification". From iOS 27 the
// automation hands the banner's message, title, subtitle and app to this
// intent, in the background, whether DiPo is open or not.
//
// NotificationTx decides whether it was a payment. A payment waits in the
// review queue (PendingInbox) until DiPo is next opened; anything else, a code,
// a promo, a reminder, is dropped without a trace.
//
// It never answers. The automation runs on every notification those apps
// send, and a "nothing saved" after each promo would be spam of its own.
// Nor does it ask for Face ID: payments arrive while the phone is locked, and
// all this can do is put a row in a queue that only the open app shows.
struct LogFromNotificationIntent: AppIntent {
    static var title: LocalizedStringResource = "Log from a Notification"
    static var description = IntentDescription(
        "For a Shortcuts automation on your bank and wallet apps' notifications. A payment goes to DiPo's review queue; codes, promos and reminders are skipped and not kept."
    )
    static var openAppWhenRun: Bool = false

    // Every one optional: an automation must never stop to ask for a value.
    @Parameter(title: "Notification", inputConnectionBehavior: .connectToPreviousIntentResult)
    var message: String?

    @Parameter(title: "Title")
    var heading: String?

    @Parameter(title: "Subtitle")
    var subtitle: String?

    @Parameter(title: "App")
    var app: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Log notification \(\.$message) titled \(\.$heading) subtitled \(\.$subtitle) from \(\.$app)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let notice = NotificationTx.Notice(body: message, title: heading, subtitle: subtitle, app: app)
        let reading = NotificationTx.read(notice, defaultCurrency: CurrencyManager.shared.preferredCurrency)
        // A note that it ran, for the guide's "is it working?": when, from
        // which app, whether it was a payment. Never what it said.
        NotificationAutomationStatus.record(app: app, title: heading, kept: reading != nil)
        guard let reading else { return .result() }

        let context = DiPoApp.sharedModelContainer.mainContext
        let cards = (try? context.fetch(FetchDescriptor<BankCard>())) ?? []
        PendingInbox.capture(
            name: reading.name,
            amount: reading.amount,
            currency: reading.currency,
            category: reading.category,
            cardID: NotificationTx.card(for: reading, in: cards)?.id,
            source: .notification,
            // The banner as it was seen, so the row can be checked against it.
            rawText: notice.shown,
            context: context
        )
        return .result()
    }
}
