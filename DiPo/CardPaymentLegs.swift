import Foundation
import SwiftData

// MARK: - One card payment, however many rows it is written as
//
// Paying a credit card writes the cash side in up to two rows, so Smart
// Budget can tell the part that pays off debt (a debt payment) from the part
// covering purchases it already counted (a transfer) — see CardPaymentDebt —
// and a third row on the card. To the person who paid, it was one payment:
// Home showed "Tokopedia CC bill payment" twice, Rp 4.250.000 and
// Rp 449.000, for one Rp 4.699.000 transfer, and deleting the one that looked
// like a duplicate left the other two saying money had moved.
//
// So lists show the cash side as one row, and a payment is deleted whole.

/// One row of a transaction list: a transaction, or the parts of one card
/// payment shown as one.
struct TxListRow: Identifiable {
    /// The part the row opens: the biggest.
    let tx: TxRecord
    /// Every part, `tx` among them; just `tx` for an ordinary row.
    let parts: [TxRecord]

    var id: UUID { tx.id }
    var isJoined: Bool { parts.count > 1 }
}

enum CardPaymentLegs {
    static let note = "tx.note.cc_payment"

    /// How far apart the card's side can be written from the cash side.
    /// Payments made today are a millisecond apart; older ones were matched
    /// within two minutes when they were split (CardPaymentDebt).
    static let window: TimeInterval = 120

    /// A row on the account the payment left.
    static func isCashSide(_ tx: TxRecord) -> Bool { tx.notes == note && tx.amount < 0 }

    /// A row on the card the payment reached.
    static func isCardSide(_ tx: TxRecord) -> Bool { tx.notes == note && tx.amount > 0 }

    /// The parts' amounts added up, in `currency`.
    static func total(_ parts: [TxRecord], in currency: String) -> Double {
        let cm = CurrencyManager.shared
        return parts.reduce(0.0) {
            $0 + cm.convert($1.amount, from: $1.currency.isEmpty ? currency : $1.currency, to: currency)
        }
    }

    /// `sorted` (newest first, as lists show them) with the cash side of each
    /// card payment as one row. Its parts are written at the same moment, so
    /// they sit next to each other.
    static func joined(_ sorted: [TxRecord]) -> [TxListRow] {
        var rows: [TxListRow] = []
        var i = 0
        while i < sorted.count {
            var parts = [sorted[i]]
            var j = i + 1
            if isCashSide(sorted[i]) {
                while j < sorted.count, isCashSide(sorted[j]),
                      abs(sorted[j].date.timeIntervalSince(sorted[i].date)) < 1 {
                    parts.append(sorted[j])
                    j += 1
                }
            }
            let main = parts.max { abs($0.amount) < abs($1.amount) } ?? sorted[i]
            rows.append(TxListRow(tx: main, parts: parts))
            i = j
        }
        return rows
    }

    /// Every row of the payment `tx` is part of: the cash side, in one or two
    /// parts, and the card's side. Just `tx` when it is not a card payment.
    static func all(of tx: TxRecord, in context: ModelContext) -> [TxRecord] {
        guard tx.notes == note else { return [tx] }
        let n = note
        let from = tx.date.addingTimeInterval(-window)
        let to = tx.date.addingTimeInterval(window)
        let nearby = (try? context.fetch(FetchDescriptor<TxRecord>(
            predicate: #Predicate { $0.notes == n && $0.date >= from && $0.date <= to }))) ?? []
        return legs(of: tx, among: nearby)
    }

    /// The rows of `tx`'s payment among `nearby` card-payment rows, `tx`
    /// included. The cash side's parts share a moment; the card's side is
    /// written just after it, for their whole amount.
    static func legs(of tx: TxRecord, among nearby: [TxRecord]) -> [TxRecord] {
        guard tx.notes == note, tx.amount != 0 else { return [tx] }
        var rows = nearby.filter { $0.notes == note && $0.id != tx.id }
        rows.append(tx)

        func cashSide(at moment: Date) -> [TxRecord] {
            rows.filter { isCashSide($0) && abs($0.date.timeIntervalSince(moment)) < 1 }
        }
        /// The card's side carries the whole cash side, in the card's currency.
        func matches(_ card: TxRecord, _ cash: [TxRecord]) -> Bool {
            guard let first = cash.first else { return false }
            let paid = abs(total(cash, in: card.currency))
            let after = card.date.timeIntervalSince(first.date)
            return abs(card.amount - paid) < max(1, paid * 0.01) && after > -1 && after <= window
        }

        if tx.amount < 0 {
            let cash = cashSide(at: tx.date)
            let card = rows.filter { isCardSide($0) && matches($0, cash) }
                .min { abs($0.date.timeIntervalSince(tx.date)) < abs($1.date.timeIntervalSince(tx.date)) }
            return cash + (card.map { [$0] } ?? [])
        }
        let cash = rows.filter { isCashSide($0) }
            .map { cashSide(at: $0.date) }
            .filter { matches(tx, $0) }
            .min { abs(tx.date.timeIntervalSince($0[0].date)) < abs(tx.date.timeIntervalSince($1[0].date)) }
        return (cash ?? []) + [tx]
    }
}
