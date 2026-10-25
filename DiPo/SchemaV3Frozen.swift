import Foundation
import SwiftData

// MARK: - Schema V3, frozen
//
// The stored shape of PhysicalAsset as it was when DiPoSchemaV4 was added —
// step 1 of "Changing a @Model" in SchemaVersions.swift. V3 changed nothing
// else, so its other models are V1's frozen copies (SchemaV1Frozen.swift).
// NEVER edit this: a V3 that stops matching what is on users' phones sends
// their ledger to StoreRecovery's quarantine.
//
// Stored properties only, with the same types and defaults as the live class
// had.

extension DiPoSchemaV3 {

    @Model
    final class PhysicalAsset {
        var id: UUID
        var kindRaw: String
        var name: String
        var currency: String
        var purchasePrice: Double
        var purchaseDate: Date
        var manualValue: Double
        var manualValueDate: Date?
        var annualRate: Double
        var taxDueDate: Date?
        var notes: String
        var createdAt: Date
        var sortOrder: Int
        var boughtUsed: Bool = false

        init() {
            self.id = UUID()
            self.kindRaw = ""
            self.name = ""
            self.currency = ""
            self.purchasePrice = 0
            self.purchaseDate = Date(timeIntervalSince1970: 0)
            self.manualValue = 0
            self.manualValueDate = nil
            self.annualRate = 0
            self.taxDueDate = nil
            self.notes = ""
            self.createdAt = Date(timeIntervalSince1970: 0)
            self.sortOrder = 0
            self.boughtUsed = false
        }
    }
}
