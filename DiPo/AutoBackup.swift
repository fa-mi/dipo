import Foundation
import SwiftData

// MARK: - A backup nobody has to remember to make
//
// Export is manual, and most people never do it. When the store then can't
// be opened (DiPo/StoreRecovery.swift) or a restore goes wrong, the advice
// "restore from a backup" leads nowhere.
//
// So DiPo keeps its own copies: the same JSON file Export produces, written
// to Application Support/AutoBackups/ at most once a day, when the app goes
// to the background. Application Support is part of the phone's iCloud or
// computer backup, so the copies also travel to a new phone restored from
// one. They do NOT help a phone that is lost without such a backup — Export
// stays the way to get a copy off the device, and its reminder still runs.
//
// What is kept: the 3 newest copies, plus the newest copy from each of the
// last 4 weeks. The weekly ones matter: if data goes missing quietly
// (deleted by mistake, a bad import), daily copies alone would all show the
// loss within 3 days.
//
// Copies are per account: the file name carries the DiPo ID, and listing and
// pruning only ever touch the signed-in account's own copies. On a shared
// phone, one person's copies neither show up for nor get pruned by another.
//
// Nothing is written when there is no data (BackupService refuses), or while
// a store-recovery notice is pending — an empty fresh start must not push
// the last good copies out.
enum AutoBackup {

    enum Reason: String {
        case daily
        /// Taken right before a restore replaces everything, so a restore
        /// of the wrong file can itself be undone.
        case beforeRestore = "before-restore"
    }

    struct Entry: Identifiable {
        let url: URL
        let date: Date
        let reason: Reason
        var id: URL { url }
    }

    /// "Daily", with slack for someone who opens the app at slightly
    /// different times each day.
    static let minInterval: TimeInterval = 20 * 60 * 60
    private static let lastRunKey = "dipo_auto_backup_last"
    private static let keepNewest = 3
    private static let keepWeeks = 4
    private static let prefix = "DiPo_Auto_"

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("AutoBackups", isDirectory: true)
    }

    /// Called when the app goes to the background. Cheap when not due.
    static func runIfDue(context: ModelContext, now: Date = .now) {
        guard UserSession.shared.dipoID != nil, StoreRecovery.pendingNotice == nil else { return }
        if let last = UserDefaults.standard.object(forKey: lastRunKey) as? Date,
           now.timeIntervalSince(last) < minInterval { return }
        do {
            try write(context: context, reason: .daily, now: now)
            UserDefaults.standard.set(now, forKey: lastRunKey)
        } catch {
            // noData / notLoggedIn are expected; nothing to report.
            print("[DiPo] Auto backup skipped: \(error)")
        }
    }

    @discardableResult
    static func write(context: ModelContext, reason: Reason, now: Date = .now) throws -> URL {
        guard let owner = UserSession.shared.dipoID else { throw BackupError.notLoggedIn }
        let data = try BackupService.encodedBackup(context: context)
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(
            "\(prefix)\(owner)_\(reason.rawValue)_\(Int(now.timeIntervalSince1970)).json")
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        // Not before a restore: that restore may be reading one of the
        // copies pruning would remove.
        if reason == .daily { prune(now: now) }
        return url
    }

    /// The signed-in account's copies, newest first. Empty when signed out.
    static func entries() -> [Entry] {
        guard let owner = UserSession.shared.dipoID else { return [] }
        let mine = prefix + owner + "_"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { name -> Entry? in
            // DiPo_Auto_<dipoID>_<reason>_<unix>.json
            guard name.hasPrefix(mine), name.hasSuffix(".json") else { return nil }
            let core = name.dropFirst(mine.count).dropLast(".json".count)
            guard let sep = core.lastIndex(of: "_"),
                  let reason = Reason(rawValue: String(core[..<sep])),
                  let stamp = TimeInterval(core[core.index(after: sep)...]) else { return nil }
            return Entry(url: directory.appendingPathComponent(name),
                         date: Date(timeIntervalSince1970: stamp), reason: reason)
        }
        .sorted { $0.date > $1.date }
    }

    static func prune(now: Date = .now) {
        let all = entries()
        let keep = kept(all, now: now)
        for entry in all where !keep.contains(entry.url) {
            try? FileManager.default.removeItem(at: entry.url)
        }
    }

    /// The retention rule on its own, so it can be tested without files.
    /// `entries` must be newest first.
    static func kept(_ entries: [Entry], now: Date) -> Set<URL> {
        var keep = Set(entries.prefix(keepNewest).map(\.url))
        var weeksSeen = Set<Int>()
        for entry in entries {   // newest first → the first of each week wins
            let week = Int(now.timeIntervalSince(entry.date) / (7 * 24 * 60 * 60))
            if week < keepWeeks, weeksSeen.insert(week).inserted { keep.insert(entry.url) }
        }
        return keep
    }
}
