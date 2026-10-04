import SwiftData

// MARK: - Versioned schema and migration plan
//
// Until now the store was opened with a bare `Schema([...])` and SwiftData's
// automatic lightweight migration. That quietly handles an added optional
// property, and nothing else: a rename, a type change, or a value that has to
// be computed from old data made the store fail to open — which used to mean
// deleting it, and now means quarantining it (DiPo/StoreRecovery.swift). Either
// way the user's ledger is gone from the app.
//
// A migration plan is how a change that lightweight migration can't infer
// still opens the old store. V1 is the schema every installed build already
// has; declaring it changes nothing on disk (StoreMigrationTests opens a store
// written without versions and finds its rows).
//
// ─── Changing a @Model from now on ────────────────────────────────────────────
//
// Any change to a stored property, relationship or @Attribute of a @Model, or
// adding/removing a @Model, is a new schema version. The steps:
//
//   1. Freeze the current version. Copy every @Model class, as it is TODAY,
//      into `DiPoSchemaV1` as nested types (`extension DiPoSchemaV1 {
//      @Model final class BankCard { … } }`), and point `models` at those
//      copies instead of the live classes. From then on V1 never changes.
//   2. Make the change on the live classes.
//   3. Add `DiPoSchemaV2` (version 2.0.0) whose `models` are the live classes,
//      and point `DiPoSchemaCurrent` at it.
//   4. Add V2 to `DiPoMigrationPlan.schemas` and a stage V1 → V2:
//      `.lightweight(fromVersion:toVersion:)` when SwiftData can infer it
//      (a new optional or defaulted property, a new model), `.custom` with a
//      `willMigrate`/`didMigrate` when values have to be moved or computed.
//   5. Update SchemaFingerprint.txt (SchemaFingerprintTests says how) and add
//      a StoreMigrationTests case that writes a V1 store and opens it as V2.
//
// Skipping step 3 is the dangerous one: with a plan in place, a store whose
// shape matches no listed version will not open at all. SchemaFingerprintTests
// exists to fail the build's tests before that ships.
//
// If the model also goes through BackupService, keep the backup in step with
// it too (see CLAUDE.md).

/// Every installed build up to 3.3. Its models are the frozen copies in
/// SchemaV1Frozen.swift — inside this enum, `BankCard` and the rest resolve to
/// those nested copies, not to the live classes.
nonisolated enum DiPoSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            BankCard.self, TxRecord.self, SalarySchedule.self,
            DebtRecord.self, SavingsGoal.self, RecurringExpense.self,
            // Money lent out. Registered here or @Query would fault at runtime.
            Receivable.self,
            // Credit-card instalments: they hold limit that no transaction
            // represents, so they need their own store.
            CardInstallment.self,
            // Per-card Smart Budget allocations (50/30/20 daily/lifestyle/invest).
            // One row per card the user has configured; cards without a row fall
            // back to global defaults from SmartBudgetManager.
            CardBudgetConfig.self,
            // Deliberate choices the user declared per pay cycle, so the engine
            // reports them instead of scoring them as mistakes.
            CycleIntent.self,
            // Investment portfolio (Royal). Holdings + their buy/sell/income lots
            // (see Investment.swift). Valued by PortfolioEngine; prices cached on
            // the holding.
            InvestmentHolding.self, InvestmentLot.self,
            // Pre-aggregated daily buckets (see RollupEngine). A derived cache of
            // the ledger — always rebuildable from TxRecord — that lets screens
            // read O(days) instead of scanning every transaction on each render.
            DailyRollup.self,
            // One row per day the user confirmed as spend-free. Without it a
            // day with no rows is indistinguishable from a day nobody logged,
            // and every per-day figure quietly treats the second as the first.
            DayCheckIn.self,
            // Read for the user, not yet theirs: everything DiPo parses waits
            // here until it has been reviewed (see DiPo/PendingInbox.swift).
            PendingTransaction.self,
        ]
    }
}

/// V2 adds physical assets (house, land, vehicles, electronics). Every other
/// model is unchanged from V1, so the step is lightweight.
nonisolated enum DiPoSchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            BankCard.self, TxRecord.self, SalarySchedule.self,
            DebtRecord.self, SavingsGoal.self, RecurringExpense.self,
            Receivable.self, CardInstallment.self, CardBudgetConfig.self,
            CycleIntent.self, InvestmentHolding.self, InvestmentLot.self,
            DailyRollup.self, DayCheckIn.self, PendingTransaction.self,
            // What the household owns outside its accounts (Royal). See
            // DiPo/PhysicalAsset.swift.
            PhysicalAsset.self,
        ]
    }
}

/// The version the app runs on. Move it forward with each new version.
typealias DiPoSchemaCurrent = DiPoSchemaV2

nonisolated enum DiPoMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [DiPoSchemaV1.self, DiPoSchemaV2.self]
    }

    static var stages: [MigrationStage] {
        [
            // A new model only: SwiftData creates its empty table.
            .lightweight(fromVersion: DiPoSchemaV1.self, toVersion: DiPoSchemaV2.self),
        ]
    }
}
