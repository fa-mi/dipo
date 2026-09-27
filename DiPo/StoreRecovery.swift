import Foundation
import SwiftData

// MARK: - Opening the store without ever deleting it
//
// When the SwiftData store failed to open, the app used to delete it and start
// empty. Every card, transaction and debt the user had was gone, with no copy
// and no word to them. For most of them this app IS the ledger; there is no
// bank statement behind it to rebuild from.
//
// Two ways that could happen for data that was perfectly fine:
//   • a schema change without a migration path. The file is intact; a later
//     build that knows how to migrate it could have opened it.
//   • a launch before the first unlock after a reboot (a silent push or a
//     background refresh). The file is encrypted until then, opening it fails,
//     and deleting it does not.
//
// Now nothing is deleted:
//   • unreadable (still locked) → stop this launch and leave the file alone.
//     A background launch dying costs nothing; the next launch opens it.
//   • readable but won't open → move the store and its side files into
//     StoreQuarantine/<timestamp>/, start empty, and tell the user once
//     (RootView) — including that the old data is still on the device and
//     where to restore a backup from. Crashlytics gets the reason.
enum StoreRecovery {

    struct Notice: Codable {
        let date: Date
        /// Folder name under StoreQuarantine/.
        let folder: String
        let reason: String
        var reported: Bool
    }

    private static let noticeKey = "dipo_store_quarantine_notice"
    private static let quarantineDirName = "StoreQuarantine"
    /// Older quarantines beyond this are removed, so repeated failures can't
    /// fill the phone. Three is enough for support to work with.
    private static let keepLast = 3

    static func openContainer(schema: Schema, config: ModelConfiguration) -> ModelContainer {
        do {
            return try ModelContainer(for: schema, configurations: config)
        } catch let openError {
            let store = config.url
            if FileManager.default.fileExists(atPath: store.path), !isReadable(store) {
                fatalError("[DiPo] Store exists but can't be read yet (device locked?) — leaving it untouched: \(openError)")
            }
            print("[DiPo] Store error, quarantining: \(openError)")
            // If the move fails, the reopen below fails too and we stop —
            // with the data still where it was.
            quarantine(store: store, reason: String(describing: openError))
            do {
                return try ModelContainer(for: schema, configurations: config)
            } catch {
                fatalError("[DiPo] SwiftData store unrecoverable after quarantine: \(error)")
            }
        }
    }

    // MARK: Notice

    static var pendingNotice: Notice? {
        guard let data = UserDefaults.standard.data(forKey: noticeKey) else { return nil }
        return try? JSONDecoder().decode(Notice.self, from: data)
    }

    /// Called from RootView's launch work rather than from inside the
    /// container's static initializer, where Firebase may not be configured.
    static func reportIfNeeded() {
        guard var notice = pendingNotice, !notice.reported else { return }
        CrashReporter.record(NSError(
            domain: "DiPo.StoreQuarantine", code: 1,
            userInfo: [NSLocalizedDescriptionKey: notice.reason,
                       "folder": notice.folder]))
        notice.reported = true
        save(notice)
    }

    /// The user has read it. The quarantined files stay.
    static func acknowledge() {
        UserDefaults.standard.removeObject(forKey: noticeKey)
    }

    // MARK: Private

    private static func isReadable(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        try? handle.close()
        return true
    }

    private static func quarantine(store: URL, reason: String) {
        let fm = FileManager.default
        let dir = store.deletingLastPathComponent()
        let root = dir.appendingPathComponent(quarantineDirName, isDirectory: true)
        let stamp = ISO8601DateFormatter().string(from: .now)
            .replacingOccurrences(of: ":", with: "-")
        let folder = root.appendingPathComponent(stamp, isDirectory: true)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            // default.store, default.store-wal, default.store-shm, and the
            // external-storage folder SwiftData keeps beside them.
            let name = store.lastPathComponent
            for file in try fm.contentsOfDirectory(atPath: dir.path) where file.hasPrefix(name) {
                try fm.moveItem(at: dir.appendingPathComponent(file),
                                to: folder.appendingPathComponent(file))
            }
        } catch {
            print("[DiPo] Quarantine move failed: \(error)")
            return
        }
        save(Notice(date: .now, folder: stamp, reason: reason, reported: false))
        prune(root)
    }

    private static func prune(_ root: URL) {
        let fm = FileManager.default
        // Timestamps sort chronologically as strings.
        guard let folders = try? fm.contentsOfDirectory(atPath: root.path).sorted(),
              folders.count > keepLast else { return }
        for old in folders.dropLast(keepLast) {
            try? fm.removeItem(at: root.appendingPathComponent(old))
        }
    }

    private static func save(_ notice: Notice) {
        if let data = try? JSONEncoder().encode(notice) {
            UserDefaults.standard.set(data, forKey: noticeKey)
        }
    }
}
