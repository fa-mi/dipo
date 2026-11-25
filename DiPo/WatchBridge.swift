import Foundation
import SwiftData
import WatchConnectivity

// MARK: - The iPhone's side of the Apple Watch
//
// Sends the watch what it shows (WatchSnapshot, as the application context:
// only the latest one matters, and the system delivers it when the watch
// wakes) and saves what the watch logs (WatchEntry, as user-info transfers:
// queued by the system and delivered once each, even if DiPo isn't running
// when they arrive).
//
// WatchConnectivity is a channel between this iPhone and its paired watch; no
// server is involved. A test run never activates it (RunContext).

@MainActor
final class WatchBridge: NSObject, WCSessionDelegate {

    static let shared = WatchBridge()

    /// Ids of the entries already saved, newest last; an entry delivered
    /// twice is saved once.
    static let seenKey = "watch.entries.seen"

    /// The latest snapshot, sent again when the session activates or the
    /// watch app is installed.
    private var latest: Data?

    private override init() { super.init() }

    /// From the app's launch. Nothing happens on a phone without a watch.
    func start() {
        guard RunContext.isOnline, WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    /// From WidgetDataSync.refresh, every time the widgets are redrawn.
    func send(_ snapshot: WatchSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        latest = data
        push()
    }

    /// After sign-out or a reset: the watch drops what it was sent and asks
    /// to open DiPo on the iPhone, like the widgets' placeholder.
    func clear() {
        latest = nil
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        try? session.updateApplicationContext([WatchSnapshot.contextKey: Data()])
    }

    private func push() {
        guard WCSession.isSupported(), let data = latest else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        do {
            try session.updateApplicationContext([WatchSnapshot.contextKey: data])
        } catch {
            print("[watch] context not sent: \(error)")
            CrashReporter.recordSDK(error, at: "watch.context")
        }
    }

    // MARK: Saving what the watch logs

    /// Saves one entry to the main card, as the Siri intent saves one: the
    /// same row, marked as coming from the watch. Returns whether it saved.
    /// Refused: an amount out of bounds, an id already saved, no main card.
    /// A category that isn't an everyday one becomes Other.
    @discardableResult
    static func save(_ entry: WatchEntry, in context: ModelContext,
                     defaults: UserDefaults = .standard, now: Date = Date()) -> Bool {
        guard DiPoIntentSupport.isRecordable(entry.amount) else { return false }
        var seen = defaults.stringArray(forKey: seenKey) ?? []
        guard !seen.contains(entry.id) else { return false }
        let cards = DiPoIntentSupport.cards(in: context)
        guard let main = DiPoIntentSupport.mainCard(in: cards) else { return false }

        let category = TxCategory(rawValue: entry.category)
            .flatMap { ExpenseCategory.categories.contains($0) ? $0 : nil } ?? .other
        // A watch clock ahead of the phone's can't post into the future.
        let tx = DiPoIntentSupport.expense(amount: entry.amount, name: category.displayLabel,
                                           category: category, currency: main.resolvedCurrency,
                                           date: min(entry.at, now), notes: "tx.note.from_watch")
        // Insert before appending, as the intent does: `transactions` has no
        // inverse, so a row added only through the array may not persist.
        context.insert(tx)
        main.transactions.append(tx)
        do {
            try context.save()
        } catch {
            print("[watch] entry not saved: \(error)")
            return false
        }
        seen.append(entry.id)
        defaults.set(Array(seen.suffix(200)), forKey: seenKey)
        return true
    }

    private static func receive(_ data: Data) {
        guard let entry = try? JSONDecoder().decode(WatchEntry.self, from: data) else { return }
        let context = DiPoApp.sharedModelContainer.mainContext
        // The refresh redraws the widgets and sends the watch the new figures.
        if save(entry, in: context) { WidgetDataSync.refresh(context: context) }
    }

    // MARK: WCSessionDelegate (called off the main thread)

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        if let error {
            print("[watch] activation failed: \(error)")
            CrashReporter.recordSDK(error, at: "watch.activate")
        }
        Task { @MainActor in self.push() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    /// The person switched watches: start again with the new one.
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.push() }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let data = userInfo[WatchEntry.userInfoKey] as? Data else { return }
        Task { @MainActor in WatchBridge.receive(data) }
    }
}
