import Foundation
import SwiftData
import Observation

// MARK: - A row changed in place
//
// Home and Statistics recompute when the NUMBER of transactions changes,
// because counting is cheap and adding or deleting is the common case. An edit
// keeps the count: a corrected amount, a moved date, a row made a loan or a
// repayment. Those went unseen until something else moved, and the rollup
// cache behind Home's flow card kept the old figure until the next launch.
//
// Anything that changes a row in place calls `edited(_:context:)`. It brings
// the rollup up to date for that row and bumps `value`, which the screens
// watch next to their transaction count.

@MainActor
@Observable
final class LedgerRevision {
    static let shared = LedgerRevision()
    private init() {}

    private(set) var value = 0

    func edited(_ tx: TxRecord, context: ModelContext) {
        RollupStore.shared.refresh(tx, context: context)
        value &+= 1
    }

    /// For settings that change what counts without touching any row.
    func bump() { value &+= 1 }
}
