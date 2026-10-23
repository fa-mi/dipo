import AppIntents
import Foundation
import SwiftData

// MARK: - Hand a bank message to DiPo
//
// iOS will not let an app read another app's notifications — there is no
// equivalent of Android's NotificationListenerService. Until iOS 27 Shortcuts
// had no "when a notification arrives" trigger either (from iOS 27 it does, and
// LogFromNotificationIntent takes those). What it has always had is a
// Communication trigger for a MESSAGE or an EMAIL, which is how many Indonesian
// banks still announce a transaction, and the only way on iOS 26 and earlier.
//
// So the user builds the automation once — "when I receive a message from BCA,
// run this" — and it calls this intent with the text. `openAppWhenRun` is false,
// so it runs in the background without taking over the phone, and the parsed
// transaction waits in the review queue until the app is next opened.
//
// Nothing leaves the device: no server, no Worker, no account needed. For
// banking messages that is not a small detail.
struct LogFromMessageIntent: AppIntent {
    static var title: LocalizedStringResource = "Log from a Bank Message"
    static var description = IntentDescription(
        "Reads a bank SMS or email and puts the transaction in DiPo's review queue. Nothing is recorded until you approve it in the app."
    )
    /// Stays in the background — the point is that the user does not have to
    /// notice this happening.
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Message")
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = ModelContext(DiPoApp.sharedModelContainer)
        let currency = CurrencyManager.shared.preferredCurrency

        guard let parsed = BankMessageParser.parse(text, defaultCurrency: currency) else {
            // Said plainly rather than filed as an empty row: a queue full of
            // blanks is worse than a message that was skipped.
            return .result(dialog: "No amount found in that message, so nothing was saved.")
        }

        let cards = (try? context.fetch(FetchDescriptor<BankCard>())) ?? []
        let card = BankMessageParser.matchCard(parsed, cards: cards)
        let category = SmartBudgetManager.suggestCategory(
            for: parsed.merchant, txType: parsed.amount < 0 ? "Expense" : "Income") ?? .other

        PendingInbox.capture(
            name: parsed.merchant,
            amount: parsed.amount,
            currency: parsed.currency,
            date: parsed.date,
            category: category,
            cardID: card?.id,
            source: .shortcut,
            // Kept so the row can be checked against the words it came from,
            // and so a parser that misreads leaves evidence behind.
            rawText: text,
            context: context
        )

        let money = CurrencyManager.shared.formatted(parsed.amount, currency: parsed.currency)
        let name = parsed.merchant.isEmpty ? "a transaction" : parsed.merchant
        return .result(dialog: "Saved \(name), \(money), for review in DiPo.")
    }
}
