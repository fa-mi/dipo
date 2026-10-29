import Foundation
import SwiftData

// MARK: - Schema V4, frozen
//
// The stored shape of HeldWant as it was when DiPoSchemaV5 was added — step 1
// of "Changing a @Model" in SchemaVersions.swift. V4 changed nothing else, so
// its other models are V1's frozen copies (SchemaV1Frozen.swift) and V3's
// PhysicalAsset (SchemaV3Frozen.swift). NEVER edit this: a V4 that stops
// matching what is on users' phones sends their ledger to StoreRecovery's
// quarantine.
//
// Stored properties only, with the same types and defaults as the live class
// had.

extension DiPoSchemaV4 {

    @Model
    final class HeldWant {
        var id: UUID
        var name: String
        var amount: Double
        var currency: String
        var addedAt: Date
        var waitDays: Int
        var readyAt: Date
        var decisionRaw: String?
        var decidedAt: Date?

        init() {
            self.id = UUID()
            self.name = ""
            self.amount = 0
            self.currency = ""
            self.addedAt = Date(timeIntervalSince1970: 0)
            self.waitDays = 0
            self.readyAt = Date(timeIntervalSince1970: 0)
            self.decisionRaw = nil
            self.decidedAt = nil
        }
    }
}
