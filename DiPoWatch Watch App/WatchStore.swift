import Foundation
import Observation
import WatchConnectivity
import WidgetKit

// MARK: - The watch's state
//
// The latest snapshot from the iPhone, kept in the App Group so the
// complications can draw it and the app shows it at once on the next launch,
// and the entries still on their way to the iPhone.

@Observable
final class WatchStore {
    static let shared = WatchStore()

    private(set) var snapshot: WatchSnapshot?
    /// Entries logged here that the iPhone hasn't received yet.
    private(set) var pending = 0

    private let link = WatchLink()

    private init() {
        snapshot = Self.stored()
        link.store = self
        link.activate()
    }

    /// Sends one expense to the iPhone, which saves it to the main card.
    /// WatchConnectivity keeps it until the iPhone can take it.
    func log(amount: Double, category: String) {
        let entry = WatchEntry(id: UUID().uuidString, amount: amount, category: category, at: Date())
        guard let data = try? JSONEncoder().encode(entry) else { return }
        link.send([WatchEntry.userInfoKey: data])
        pending = link.outstanding
    }

    // MARK: From the link

    func received(_ data: Data) {
        let defaults = UserDefaults(suiteName: WatchSnapshot.appGroupID)
        if let next = try? JSONDecoder().decode(WatchSnapshot.self, from: data) {
            snapshot = next
            defaults?.set(data, forKey: WatchSnapshot.storeKey)
        } else {
            // An empty snapshot: signed out or reset on the iPhone.
            snapshot = nil
            defaults?.removeObject(forKey: WatchSnapshot.storeKey)
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    func transfersChanged() {
        pending = link.outstanding
    }

    private static func stored() -> WatchSnapshot? {
        UserDefaults(suiteName: WatchSnapshot.appGroupID)?
            .data(forKey: WatchSnapshot.storeKey)
            .flatMap { try? JSONDecoder().decode(WatchSnapshot.self, from: $0) }
    }
}

// MARK: - The connection to the iPhone

final class WatchLink: NSObject, WCSessionDelegate {
    weak var store: WatchStore?
    /// Entries logged before the session was ready, sent once it is.
    private var waiting: [[String: Any]] = []

    var outstanding: Int {
        WCSession.default.outstandingUserInfoTransfers.count + waiting.count
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func send(_ info: [String: Any]) {
        guard WCSession.default.activationState == .activated else {
            waiting.append(info)
            return
        }
        WCSession.default.transferUserInfo(info)
    }

    private func flush() {
        let queued = waiting
        waiting.removeAll()
        for info in queued { WCSession.default.transferUserInfo(info) }
        store?.transfersChanged()
    }

    // MARK: WCSessionDelegate (called off the main thread)

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        let context = session.receivedApplicationContext[WatchSnapshot.contextKey] as? Data
        Task { @MainActor in
            if activationState == .activated { self.flush() }
            if let context { self.store?.received(context) }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext[WatchSnapshot.contextKey] as? Data else { return }
        Task { @MainActor in self.store?.received(data) }
    }

    nonisolated func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: Error?) {
        Task { @MainActor in self.store?.transfersChanged() }
    }
}
