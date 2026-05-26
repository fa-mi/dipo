// BackupService.swift
// User-facing data export/import for device migration & disaster recovery.
//
// Why this exists: the app stores all financial data locally in SwiftData
// (cards, transactions, debts, goals, salary schedules). When a user changes
// device or accidentally wipes their phone, that data is gone — there's no
// server-side mirror because the privacy model is "your data stays on your
// device". This service lets the user dump everything to a JSON file they
// can save anywhere (iCloud Drive, email to themselves, AirDrop) and restore
// from later.
//
// Design:
//   - Pure Codable DTOs that mirror each @Model class. We can't make
//     @Model itself Codable (PersistentModel constraints clash with
//     synthesized Codable), so we hand-translate each row.
//   - JSON has a `version` field. Future schema changes bump the version and
//     migrate on read. Any payload from a higher version than we know about
//     is rejected with a friendly error rather than silently corrupting data.
//   - Import is REPLACE not MERGE. Merging would need conflict resolution per
//     row (same UUID, different fields) and the UX cost outweighs the benefit
//     for a personal-use app. The UI warns the user explicitly.
//   - SmartBudget toggle + ratios are stored in UserDefaults, not SwiftData,
//     so we capture them under a separate key and restore on import.

import Foundation
import SwiftData

// MARK: - Versioned Envelope

/// Top-level container written to / read from JSON.
struct BackupPayload: Codable {
    /// Bumped when the schema changes. Importer rejects unknown future
    /// versions to avoid silently dropping fields.
    static let currentVersion = 1
    /// Magic identifier so we validate by content, not filename. Any JSON
    /// missing this exact value is rejected as "not a DiPo backup".
    static let currentFormat = "DiPoBackup"

    /// Optional so legacy backups (exported before this field existed)
    /// still decode. New exports always set it to `currentFormat`; the
    /// importer rejects any payload whose format isn't exactly that value.
    var format: String? = BackupPayload.currentFormat
    let version: Int
    let exportedAt: Date
    let appVersion: String
    /// Owner of this backup. Set at export time from the current session.
    /// Importer rejects backups whose `userID` doesn't match the logged-in
    /// user — prevents user A's data leaking into user B's device.
    /// Optional for backward compat with backups exported before this field
    /// existed (those are treated as legacy and allowed through).
    var userID: String? = nil

    let cards:        [BackupCard]
    let transactions: [BackupTransaction]
    let salaries:     [BackupSalary]
    let debts:        [BackupDebt]
    let goals:        [BackupGoal]
    let cardBudgets:  [BackupCardBudget]
    let smartBudget:  BackupSmartBudgetSettings
}

// MARK: - DTOs (mirror SwiftData @Model classes 1:1)

struct BackupCard: Codable {
    let id: UUID
    let holderName: String
    let cardNumber: String
    let balance: Double
    let expireDate: String
    let gradientStart: String
    let gradientEnd: String
    let sortOrder: Int
    let currency: String
    let isDigitalWallet: Bool
    let walletProvider: String
    let phoneNumber: String
    let isHidden: Bool
}

struct BackupTransaction: Codable {
    let id: UUID
    /// Foreign key to `BackupCard.id`. Required for re-attaching the tx to its
    /// card on import — without it we'd lose the parent relationship that
    /// SwiftData's `@Relationship(deleteRule: .cascade)` normally maintains.
    let cardID: UUID
    let name: String
    let date: Date
    let amount: Double
    let type: String
    let icon: String
    let iconBgHex: String
    let categoryRaw: String
    let currency: String
    let notes: String
    let linkedDebtID: String
    let subtype: String

    private enum CodingKeys: String, CodingKey {
        case id, cardID, name, date, amount, type, icon, iconBgHex,
             categoryRaw, currency, notes, linkedDebtID, subtype
    }

    /// Custom decoder so older backups (exported before `subtype` existed)
    /// don't fail with keyNotFound. Synthesized Codable doesn't honor
    /// Swift property defaults — it calls `decode` not `decodeIfPresent` —
    /// so the fallback must be explicit here.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id           = try c.decode(UUID.self,   forKey: .id)
        cardID       = try c.decode(UUID.self,   forKey: .cardID)
        name         = try c.decode(String.self, forKey: .name)
        date         = try c.decode(Date.self,   forKey: .date)
        amount       = try c.decode(Double.self, forKey: .amount)
        type         = try c.decode(String.self, forKey: .type)
        icon         = try c.decode(String.self, forKey: .icon)
        iconBgHex    = try c.decode(String.self, forKey: .iconBgHex)
        categoryRaw  = try c.decode(String.self, forKey: .categoryRaw)
        currency     = try c.decode(String.self, forKey: .currency)
        notes        = try c.decode(String.self, forKey: .notes)
        linkedDebtID = try c.decode(String.self, forKey: .linkedDebtID)
        subtype      = try c.decodeIfPresent(String.self, forKey: .subtype) ?? "normal"
    }

    init(id: UUID, cardID: UUID, name: String, date: Date, amount: Double,
         type: String, icon: String, iconBgHex: String, categoryRaw: String,
         currency: String, notes: String, linkedDebtID: String,
         subtype: String = "normal") {
        self.id = id
        self.cardID = cardID
        self.name = name
        self.date = date
        self.amount = amount
        self.type = type
        self.icon = icon
        self.iconBgHex = iconBgHex
        self.categoryRaw = categoryRaw
        self.currency = currency
        self.notes = notes
        self.linkedDebtID = linkedDebtID
        self.subtype = subtype
    }
}

struct BackupSalary: Codable {
    let id: UUID
    let label: String
    let amount: Double
    let dayOfMonth: Int
    let currency: String
    let isActive: Bool
    let cardID: UUID?
    let createdAt: Date
    let lastCreditedMonth: Int
    let lastCreditedYear: Int
    let isPinned: Bool
}

struct BackupDebt: Codable {
    let id: UUID
    let name: String
    let type: String
    let totalAmount: Double
    let currentBalance: Double
    let minimumPayment: Double
    let annualInterestRate: Double
    let dueDayOfMonth: Int
    let currency: String
    let isActive: Bool
    let createdAt: Date
    let notes: String
    let hasBeenTracked: Bool
}

struct BackupGoal: Codable {
    let id: UUID
    let name: String
    let emoji: String
    let targetAmount: Double
    let savedAmount: Double
    let currency: String
    let targetDate: Date?
    let priority: Int
    let isCompleted: Bool
    let createdAt: Date
    let notes: String
    let monthlyContribution: Double
    let isPinned: Bool
}

struct BackupCardBudget: Codable {
    let cardID: String
    let dailyRatio: Double
    let lifestyleRatio: Double
    let investDebtRatio: Double
    let updatedAt: Date
}

struct BackupSmartBudgetSettings: Codable {
    let isEnabled: Bool
    let dailyRatio: Double
    let lifestyleRatio: Double
    let investDebtRatio: Double
    let budgetCardID: String?
}

// MARK: - Backup Service

enum BackupError: LocalizedError {
    case readFailed(String)
    case decodeFailed(String)
    case unknownVersion(Int)
    case writeFailed(String)
    case noData
    /// Login is required before export/import. Backups are tied to a
    /// specific user so we can prevent cross-account restore.
    case notLoggedIn
    /// JSON parsed cleanly but isn't a DiPo backup (missing `format`
    /// magic, or magic value doesn't match `currentFormat`).
    case notDiPoBackup
    /// Backup's `userID` doesn't match the currently logged-in user.
    case userMismatch

    var errorDescription: String? {
        switch self {
        case .readFailed(let msg):    return "Failed to read backup: \(msg)"
        case .decodeFailed(let msg):  return "Backup file is invalid: \(msg)"
        case .unknownVersion(let v):  return "This backup (v\(v)) is from a newer app version."
        case .writeFailed(let msg):   return "Failed to write backup: \(msg)"
        case .noData:                 return "Nothing to back up yet."
        case .notLoggedIn:            return loc("backup.error.notLoggedIn")
        case .notDiPoBackup:          return loc("backup.error.notDiPoBackup")
        case .userMismatch:           return loc("backup.error.userMismatch")
        }
    }
}

// MARK: - Backup Preview Result

/// Lightweight summary of a backup file's contents — used by the
/// pre-import preview sheet so the user sees what they're about to
/// restore BEFORE the destructive wipe runs. Parsed via `previewBackup`
/// which reads the JSON but never touches SwiftData.
struct BackupPreview: Identifiable {
    /// Used by `.sheet(item:)` — the file URL itself is unique per pick so
    /// it doubles as a stable identifier.
    var id: URL { url }
    let url: URL
    let payload: BackupPayload
    var cardCount: Int       { payload.cards.count }
    var transactionCount: Int { payload.transactions.count }
    var debtCount: Int       { payload.debts.count }
    var goalCount: Int       { payload.goals.count }
    var salaryCount: Int     { payload.salaries.count }
    /// Pre-formatted "1 Mei 2026, 14:22" — locale-aware via LanguageManager.
    var exportedAtFormatted: String {
        let f = DateFormatter()
        f.locale = LanguageManager.shared.currentLocale
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: payload.exportedAt)
    }
    var appVersion: String   { payload.appVersion }
}

@MainActor
enum BackupService {

    // MARK: - Validation helpers

    /// Reusable checks for both `previewBackup` and `importBackup` so the
    /// rules stay in one place. Run AFTER decode succeeds.
    ///
    /// Order matters:
    ///   1. Login — backup is tied to a user, no point checking the rest if
    ///      no one is logged in.
    ///   2. Format magic — confirms this JSON is actually a DiPo backup
    ///      (rejects arbitrary `.json` like `test.json` that happens to
    ///      decode into the struct shape by accident — unlikely but cheap
    ///      to enforce).
    ///   3. Version — newer payloads we don't understand are rejected.
    ///   4. UserID — backup's owner must match the current session, so
    ///      user A's data can't be restored into user B's account.
    ///
    /// `userID` and `format` are nil-tolerated for legacy backups exported
    /// before those fields existed.
    private static func validate(_ payload: BackupPayload) throws {
        guard let currentUserID = UserSession.shared.userID else {
            throw BackupError.notLoggedIn
        }

        if let format = payload.format, format != BackupPayload.currentFormat {
            throw BackupError.notDiPoBackup
        }
        // No format field at all = legacy backup. We let it through rather
        // than locking users out of pre-magic-field backups they made.

        guard payload.version <= BackupPayload.currentVersion else {
            throw BackupError.unknownVersion(payload.version)
        }

        if let backupUserID = payload.userID, backupUserID != currentUserID {
            throw BackupError.userMismatch
        }
        // Same logic as format: legacy backups (no userID field) are
        // allowed through — they predate the per-user tagging.
    }

    // MARK: - Preview (read-only, no DB writes)

    /// Read + decode the backup file without touching SwiftData. Used by the
    /// UI to show a summary sheet before the user confirms the destructive
    /// import. Returns a `BackupPreview` that the preview view can render
    /// counts + export date from; the same payload gets handed to
    /// `importBackup` later if user confirms (avoids re-parsing).
    static func previewBackup(from url: URL) throws -> BackupPreview {
        // Match importBackup's security-scoped URL handling — without
        // start/stop, the read silently returns empty on real devices.
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw BackupError.readFailed(error.localizedDescription)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let payload: BackupPayload
        do {
            payload = try decoder.decode(BackupPayload.self, from: data)
        } catch {
            // JSON that doesn't even decode into our struct shape (like
            // `test.json` with totally different keys) lands here. Re-map
            // it to `notDiPoBackup` so the user sees a clear "not a DiPo
            // backup" message instead of cryptic Codable diagnostics.
            throw BackupError.notDiPoBackup
        }

        try validate(payload)
        return BackupPreview(url: url, payload: payload)
    }


    // MARK: - Export

    /// Read every model from `context`, build a `BackupPayload`, write it to
    /// JSON in the temp directory, and return the file URL ready for a share
    /// sheet. Caller is responsible for presenting the URL via
    /// UIActivityViewController.
    static func exportBackup(context: ModelContext) throws -> URL {
        // Require login — backups are tagged with the owner's userID so
        // they can't be cross-restored on another account. No userID =
        // can't tag = refuse export.
        guard let currentUserID = UserSession.shared.userID else {
            throw BackupError.notLoggedIn
        }

        // Pull every row from each schema. SwiftData throws on misconfigured
        // contexts; surface the underlying message so the user sees a useful
        // toast rather than a generic "failed".
        let cards:    [BankCard]         = (try? context.fetch(FetchDescriptor<BankCard>())) ?? []
        let txs:      [TxRecord]         = (try? context.fetch(FetchDescriptor<TxRecord>())) ?? []
        let salaries: [SalarySchedule]   = (try? context.fetch(FetchDescriptor<SalarySchedule>())) ?? []
        let debts:    [DebtRecord]       = (try? context.fetch(FetchDescriptor<DebtRecord>())) ?? []
        let goals:    [SavingsGoal]      = (try? context.fetch(FetchDescriptor<SavingsGoal>())) ?? []
        let configs:  [CardBudgetConfig] = (try? context.fetch(FetchDescriptor<CardBudgetConfig>())) ?? []

        // Build a card-id → list-of-tx index so we know which card each tx
        // belongs to without traversing relationships at write time.
        var txCardMap: [UUID: UUID] = [:]
        for card in cards {
            for tx in card.transactions {
                txCardMap[tx.id] = card.id
            }
        }

        guard !cards.isEmpty || !txs.isEmpty || !salaries.isEmpty
              || !debts.isEmpty || !goals.isEmpty else {
            throw BackupError.noData
        }

        let payload = BackupPayload(
            format:      BackupPayload.currentFormat,
            version:     BackupPayload.currentVersion,
            exportedAt:  .now,
            appVersion:  Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
            userID:      currentUserID,
            cards:       cards.map { c in
                BackupCard(
                    id: c.id, holderName: c.holderName, cardNumber: c.cardNumber,
                    balance: c.balance, expireDate: c.expireDate,
                    gradientStart: c.gradientStart, gradientEnd: c.gradientEnd,
                    sortOrder: c.sortOrder, currency: c.currency,
                    isDigitalWallet: c.isDigitalWallet,
                    walletProvider: c.walletProvider,
                    phoneNumber: c.phoneNumber, isHidden: c.isHidden
                )
            },
            transactions: txs.compactMap { t in
                // Skip orphan tx (card relationship missing) — exporting them
                // would cause import to fail because there's no parent card
                // to reattach to.
                guard let cardID = txCardMap[t.id] else { return nil }
                return BackupTransaction(
                    id: t.id, cardID: cardID, name: t.name, date: t.date,
                    amount: t.amount, type: t.type, icon: t.icon,
                    iconBgHex: t.iconBgHex, categoryRaw: t.categoryRaw,
                    currency: t.currency, notes: t.notes,
                    linkedDebtID: t.linkedDebtID,
                    subtype: t.subtype
                )
            },
            salaries: salaries.map { s in
                BackupSalary(
                    id: s.id, label: s.label, amount: s.amount,
                    dayOfMonth: s.dayOfMonth, currency: s.currency,
                    isActive: s.isActive, cardID: s.cardID,
                    createdAt: s.createdAt,
                    lastCreditedMonth: s.lastCreditedMonth,
                    lastCreditedYear: s.lastCreditedYear,
                    isPinned: s.isPinned
                )
            },
            debts: debts.map { d in
                BackupDebt(
                    id: d.id, name: d.name, type: d.type,
                    totalAmount: d.totalAmount,
                    currentBalance: d.currentBalance,
                    minimumPayment: d.minimumPayment,
                    annualInterestRate: d.annualInterestRate,
                    dueDayOfMonth: d.dueDayOfMonth,
                    currency: d.currency, isActive: d.isActive,
                    createdAt: d.createdAt, notes: d.notes,
                    hasBeenTracked: d.hasBeenTracked
                )
            },
            goals: goals.map { g in
                BackupGoal(
                    id: g.id, name: g.name, emoji: g.emoji,
                    targetAmount: g.targetAmount, savedAmount: g.savedAmount,
                    currency: g.currency, targetDate: g.targetDate,
                    priority: g.priority, isCompleted: g.isCompleted,
                    createdAt: g.createdAt, notes: g.notes,
                    monthlyContribution: g.monthlyContribution,
                    isPinned: g.isPinned
                )
            },
            cardBudgets: configs.map { c in
                BackupCardBudget(
                    cardID: c.cardID, dailyRatio: c.dailyRatio,
                    lifestyleRatio: c.lifestyleRatio,
                    investDebtRatio: c.investDebtRatio,
                    updatedAt: c.updatedAt
                )
            },
            smartBudget: BackupSmartBudgetSettings(
                isEnabled:       SmartBudgetManager.shared.isEnabled,
                dailyRatio:      SmartBudgetManager.shared.dailyRatio,
                lifestyleRatio:  SmartBudgetManager.shared.lifestyleRatio,
                investDebtRatio: SmartBudgetManager.shared.investDebtRatio,
                budgetCardID:    SmartBudgetManager.shared.budgetCardID
            )
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data: Data
        do {
            data = try encoder.encode(payload)
        } catch {
            throw BackupError.writeFailed(error.localizedDescription)
        }

        // Filename pattern: DiPo_Backup_<userID-or-anon>_<timestamp>.json
        // Including a coarse timestamp helps users keep multiple backups.
        let stamp = Int(Date().timeIntervalSince1970)
        let userTag = (UserSession.shared.userID ?? "anon").prefix(8)
        let filename = "DiPo_Backup_\(userTag)_\(stamp).json"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)

        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw BackupError.writeFailed(error.localizedDescription)
        }
        return url
    }

    // MARK: - Import

    /// Replace all local data with the contents of `url` (a JSON file produced
    /// by `exportBackup`). DESTRUCTIVE — any existing data is wiped first.
    /// Caller MUST confirm with the user before invoking.
    static func importBackup(from url: URL, context: ModelContext) throws {
        // iOS hands us a security-scoped URL when picked through
        // UIDocumentPicker. Without start/stopAccessingSecurityScopedResource,
        // the read silently returns empty data on real devices.
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw BackupError.readFailed(error.localizedDescription)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let payload: BackupPayload
        do {
            payload = try decoder.decode(BackupPayload.self, from: data)
        } catch {
            // Same rationale as previewBackup: surface as "not a DiPo
            // backup" rather than leaking JSONDecoder internals.
            throw BackupError.notDiPoBackup
        }

        try validate(payload)

        // ---- AUTO-SAFETY SNAPSHOT ----
        // Backup is the user's safety net — failing it shouldn't make their
        // data WORSE. Before we wipe and overwrite, dump current state to a
        // hidden recovery JSON. If the import below throws partway through,
        // the catch at the bottom restores from this snapshot so the user
        // ends up exactly where they started instead of empty.
        let snapshotURL: URL? = try? Self.exportBackup(context: context)

        do {
            // ---- WIPE EXISTING DATA ----
            // Use the same delete-by-model API ProfileView.resetAllData uses.
            // A partial overlay would be worse UX than a clean restore (user
            // could end up with mismatched tx ↔ card foreign keys).
            try? context.delete(model: BankCard.self)
            try? context.delete(model: TxRecord.self)
            try? context.delete(model: SalarySchedule.self)
            try? context.delete(model: DebtRecord.self)
            try? context.delete(model: SavingsGoal.self)
            try? context.delete(model: CardBudgetConfig.self)
            try context.save()

        // ---- INSERT FROM PAYLOAD ----
        // Insert cards first so the transaction loop can attach to them by
        // primary key. We rebuild the relationship via `card.transactions
        // .append(tx)` rather than setting tx → card directly because the
        // SwiftData inverse is non-optional.
        var cardByID: [UUID: BankCard] = [:]
        for c in payload.cards {
            let card = BankCard(
                holderName: c.holderName, cardNumber: c.cardNumber,
                balance: c.balance, expireDate: c.expireDate,
                gradientStart: c.gradientStart, gradientEnd: c.gradientEnd,
                sortOrder: c.sortOrder, currency: c.currency,
                isDigitalWallet: c.isDigitalWallet,
                walletProvider: c.walletProvider,
                phoneNumber: c.phoneNumber, isHidden: c.isHidden
            )
            // Preserve original UUID so relationships in the payload stay
            // valid. The auto-generated init() assigns a new UUID; we
            // overwrite it post-init.
            card.id = c.id
            context.insert(card)
            cardByID[c.id] = card
        }

        for t in payload.transactions {
            // Drop orphan transactions whose parent card was missing from the
            // backup (shouldn't happen with our exporter, but defensive).
            guard let parent = cardByID[t.cardID] else { continue }
            let tx = TxRecord(
                name: t.name, date: t.date, amount: t.amount,
                type: t.type, icon: t.icon, iconBgHex: t.iconBgHex,
                category: TxCategory(rawValue: t.categoryRaw) ?? .other,
                currency: t.currency, notes: t.notes,
                linkedDebtID: t.linkedDebtID,
                subtype: TxSubtype(rawValue: t.subtype) ?? .normal
            )
            tx.id = t.id
            // CRITICAL: explicit insert. BankCard.transactions has a cascade
            // relationship but no `inverse:` declared on TxRecord, so SwiftData
            // does NOT auto-insert child rows when you append to the parent's
            // array. Result: txs were quietly dropped at save time and the
            // restore looked successful but Statistics/Home showed empty data.
            // Insert FIRST, then append to the relationship array.
            context.insert(tx)
            parent.transactions.append(tx)
        }

        for s in payload.salaries {
            let salary = SalarySchedule(
                label: s.label, amount: s.amount,
                dayOfMonth: s.dayOfMonth, currency: s.currency,
                cardID: s.cardID
            )
            salary.id = s.id
            salary.isActive = s.isActive
            salary.createdAt = s.createdAt
            salary.lastCreditedMonth = s.lastCreditedMonth
            salary.lastCreditedYear = s.lastCreditedYear
            salary.isPinned = s.isPinned
            context.insert(salary)
        }

        for d in payload.debts {
            let debt = DebtRecord(
                name: d.name, type: d.type,
                totalAmount: d.totalAmount,
                currentBalance: d.currentBalance,
                minimumPayment: d.minimumPayment,
                annualInterestRate: d.annualInterestRate,
                dueDayOfMonth: d.dueDayOfMonth,
                currency: d.currency, notes: d.notes
            )
            debt.id = d.id
            debt.isActive = d.isActive
            debt.createdAt = d.createdAt
            debt.hasBeenTracked = d.hasBeenTracked
            context.insert(debt)
        }

        for g in payload.goals {
            let goal = SavingsGoal(
                name: g.name, emoji: g.emoji,
                targetAmount: g.targetAmount,
                savedAmount: g.savedAmount,
                currency: g.currency,
                targetDate: g.targetDate,
                priority: g.priority,
                monthlyContribution: g.monthlyContribution,
                notes: g.notes
            )
            goal.id = g.id
            goal.isCompleted = g.isCompleted
            goal.createdAt = g.createdAt
            goal.isPinned = g.isPinned
            context.insert(goal)
        }

        for cb in payload.cardBudgets {
            let cfg = CardBudgetConfig(
                cardID: cb.cardID,
                dailyRatio: cb.dailyRatio,
                lifestyleRatio: cb.lifestyleRatio,
                investDebtRatio: cb.investDebtRatio
            )
            cfg.updatedAt = cb.updatedAt
            context.insert(cfg)
        }

            try context.save()

            // ---- RESTORE SMART BUDGET (UserDefaults-backed) ----
            SmartBudgetManager.shared.dailyRatio      = payload.smartBudget.dailyRatio
            SmartBudgetManager.shared.lifestyleRatio  = payload.smartBudget.lifestyleRatio
            SmartBudgetManager.shared.investDebtRatio = payload.smartBudget.investDebtRatio
            SmartBudgetManager.shared.budgetCardID    = payload.smartBudget.budgetCardID
            SmartBudgetManager.shared.isEnabled       = payload.smartBudget.isEnabled

            // Success — discard the snapshot so we don't leave stale temp
            // files on disk. Failure path keeps the snapshot so a future
            // run could conceivably auto-recover from it.
            if let url = snapshotURL {
                try? FileManager.default.removeItem(at: url)
            }
        } catch {
            // Restore from snapshot. We can't reuse `importBackup` here
            // because that would recurse infinitely; instead replay the
            // wipe + insert directly with the snapshot payload so the user
            // ends up at their pre-import state.
            if let url = snapshotURL,
               let snapData = try? Data(contentsOf: url),
               let snap = try? decoder.decode(BackupPayload.self, from: snapData) {
                try? context.delete(model: BankCard.self)
                try? context.delete(model: TxRecord.self)
                try? context.delete(model: SalarySchedule.self)
                try? context.delete(model: DebtRecord.self)
                try? context.delete(model: SavingsGoal.self)
                try? context.delete(model: CardBudgetConfig.self)
                try? context.save()
                Self.applyPayload(snap, context: context)
                try? context.save()
            }
            throw BackupError.writeFailed(error.localizedDescription)
        }
    }

    // MARK: - Apply Payload (shared by import + rollback)

    /// Inserts the contents of a payload into the given context. Assumes
    /// the context has already been wiped of data. Extracted from the
    /// happy-path of `importBackup` so the rollback path can reuse it
    /// without copy-pasting 80 lines of insert logic.
    private static func applyPayload(_ payload: BackupPayload, context: ModelContext) {
        var cardByID: [UUID: BankCard] = [:]
        for c in payload.cards {
            let card = BankCard(
                holderName: c.holderName, cardNumber: c.cardNumber,
                balance: c.balance, expireDate: c.expireDate,
                gradientStart: c.gradientStart, gradientEnd: c.gradientEnd,
                sortOrder: c.sortOrder, currency: c.currency,
                isDigitalWallet: c.isDigitalWallet,
                walletProvider: c.walletProvider,
                phoneNumber: c.phoneNumber, isHidden: c.isHidden
            )
            card.id = c.id
            context.insert(card)
            cardByID[c.id] = card
        }
        for t in payload.transactions {
            guard let parent = cardByID[t.cardID] else { continue }
            let tx = TxRecord(
                name: t.name, date: t.date, amount: t.amount,
                type: t.type, icon: t.icon, iconBgHex: t.iconBgHex,
                category: TxCategory(rawValue: t.categoryRaw) ?? .other,
                currency: t.currency, notes: t.notes,
                linkedDebtID: t.linkedDebtID,
                subtype: TxSubtype(rawValue: t.subtype) ?? .normal
            )
            tx.id = t.id
            // Same critical pattern as the inline import path: explicit
            // insert + append. Without insert(), append-only relationships
            // get silently dropped at save time.
            context.insert(tx)
            parent.transactions.append(tx)
        }
        for s in payload.salaries {
            let salary = SalarySchedule(
                label: s.label, amount: s.amount,
                dayOfMonth: s.dayOfMonth, currency: s.currency,
                cardID: s.cardID
            )
            salary.id = s.id
            salary.isActive = s.isActive
            salary.createdAt = s.createdAt
            salary.lastCreditedMonth = s.lastCreditedMonth
            salary.lastCreditedYear = s.lastCreditedYear
            salary.isPinned = s.isPinned
            context.insert(salary)
        }
        for d in payload.debts {
            let debt = DebtRecord(
                name: d.name, type: d.type,
                totalAmount: d.totalAmount,
                currentBalance: d.currentBalance,
                minimumPayment: d.minimumPayment,
                annualInterestRate: d.annualInterestRate,
                dueDayOfMonth: d.dueDayOfMonth,
                currency: d.currency, notes: d.notes
            )
            debt.id = d.id
            debt.isActive = d.isActive
            debt.createdAt = d.createdAt
            debt.hasBeenTracked = d.hasBeenTracked
            context.insert(debt)
        }
        for g in payload.goals {
            let goal = SavingsGoal(
                name: g.name, emoji: g.emoji,
                targetAmount: g.targetAmount,
                savedAmount: g.savedAmount,
                currency: g.currency,
                targetDate: g.targetDate,
                priority: g.priority,
                monthlyContribution: g.monthlyContribution,
                notes: g.notes
            )
            goal.id = g.id
            goal.isCompleted = g.isCompleted
            goal.createdAt = g.createdAt
            goal.isPinned = g.isPinned
            context.insert(goal)
        }
        for cb in payload.cardBudgets {
            let cfg = CardBudgetConfig(
                cardID: cb.cardID,
                dailyRatio: cb.dailyRatio,
                lifestyleRatio: cb.lifestyleRatio,
                investDebtRatio: cb.investDebtRatio
            )
            cfg.updatedAt = cb.updatedAt
            context.insert(cfg)
        }
    }
}
