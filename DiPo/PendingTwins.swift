import Foundation

// MARK: - Two rows, one payment?
//
// With notifications feeding the queue, one payment can arrive twice. Paying
// with ShopeePay inside Shopee is announced by both apps, and topping GoPay up
// from a bank is one move told from each end: out of the bank, into GoPay.
//
// The queue doesn't merge them on its own. Two coffees at the same price a
// minute apart are real too, and a payment dropped as a "duplicate" is one
// nobody notices is missing. So it says what it sees, on both rows, and the
// user decides: swipe one away, or record a move as the transfer it was.

enum PendingTwins {

    enum Kind: Equatable {
        /// Same amount, same way: one payment, announced twice?
        case repeated
        /// Same amount, one out and one in: a move between the user's own cards?
        case crossed
    }

    /// Rows read this close together are one moment. Two apps announce one
    /// payment within seconds; a receipt scanned after paying, within minutes.
    static let window: TimeInterval = 10 * 60

    /// Another row of the same amount and currency, read within `window` of
    /// this one. Crossed outranks repeated: recording a move between cards as
    /// spending is the bigger mistake.
    static func kind(of item: PendingTransaction, among rows: [PendingTransaction]) -> Kind? {
        let twins = self.twins(of: item, among: rows)
        if twins.contains(where: { crosses($0, item) }) { return .crossed }
        return twins.isEmpty ? nil : .repeated
    }

    /// The other half of a crossed pair: opposite in sign, nearest in time.
    static func crossedPartner(of item: PendingTransaction,
                               among rows: [PendingTransaction]) -> PendingTransaction? {
        twins(of: item, among: rows)
            .filter { crosses($0, item) }
            .min { gap($0, item) < gap($1, item) }
    }

    /// A held bill has its own note and is left out.
    private static func twins(of item: PendingTransaction,
                              among rows: [PendingTransaction]) -> [PendingTransaction] {
        guard item.source != .recurring, item.amount != 0 else { return [] }
        return rows.filter { other in
            other.id != item.id && other.source != .recurring
                && other.currency == item.currency
                && abs(abs(other.amount) - abs(item.amount)) < 0.5
                && gap(other, item) <= window
        }
    }

    private static func crosses(_ a: PendingTransaction, _ b: PendingTransaction) -> Bool {
        (a.amount < 0) != (b.amount < 0)
    }

    private static func gap(_ a: PendingTransaction, _ b: PendingTransaction) -> TimeInterval {
        abs(a.capturedAt.timeIntervalSince(b.capturedAt))
    }
}
