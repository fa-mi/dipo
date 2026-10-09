import Foundation

// MARK: - Where "between your own accounts" came from and went
//
// The cash book folds every move between the person's own cards into one
// line: "Between your own accounts +Rp 1.950.000". On 8 Oct Dad paid back
// Rp 2.500.000 into BCA, and Fahmi moved Rp 2.600.000 from BCA to BRI the
// same day. Statistics reads BRI, so the repayment seemed to have vanished.
// It had arrived, but as part of a transfer, inside a total.
//
// This breaks the line down by the other card and direction. For money that
// came in from a card outside the pot, it also names what came into that
// card just before (Dad's repayment). That is said as what happened before
// the move, not as a claim about which rupiah moved.
//
// The two legs of a transfer are separate rows with no link between them
// (CardManagementView writes them a moment apart), so the other card is found
// by pairing: the ⇄ row on another card, opposite in sign, written within
// two minutes, closest in amount.

enum OwnMoves {

    struct Source: Identifiable, Equatable {
        let id: UUID
        let name: String
        let amount: Double
        let date: Date
    }

    struct Line: Identifiable, Equatable {
        let id: String
        let incoming: Bool
        /// The other card's name, or the row's own name when the other leg
        /// can't be found (deleted, or written before transfers had two legs).
        let label: String
        /// Magnitude, in the screen's currency.
        let amount: Double
        /// Incoming only: money in on the other card shortly before the move.
        let sources: [Source]
    }

    static let pairWindow: TimeInterval = 120
    static let sourceWindowDays = 7
    static let maxSources = 3

    /// The other leg of a card-to-card transfer, and the card it sits on.
    static func counterpart(of tx: TxRecord, ownCardID: UUID?,
                            in cards: [BankCard]) -> (card: BankCard, tx: TxRecord)? {
        guard tx.icon == "⇄" else { return nil }
        let cm = CurrencyManager.shared
        var best: (card: BankCard, tx: TxRecord, gap: Double)?
        for card in cards where card.id != ownCardID {
            for other in card.transactions where other.icon == "⇄"
                && (other.amount > 0) != (tx.amount > 0)
                && abs(other.date.timeIntervalSince(tx.date)) <= pairWindow {
                let gap = abs(abs(cm.convert(other.amount, from: other.currency, to: tx.currency)) - abs(tx.amount))
                if best == nil || gap < best!.gap { best = (card, other, gap) }
            }
        }
        return best.map { ($0.card, $0.tx) }
    }

    /// Money in on `card` in the week up to `move` (same day included):
    /// anything that isn't itself a move between own cards. Largest first.
    static func sources(before move: TxRecord, on card: BankCard,
                        convert: (TxRecord) -> Double) -> [Source] {
        let cal = Calendar.current
        let from = cal.date(byAdding: .day, value: -sourceWindowDays, to: cal.startOfDay(for: move.date))
            ?? .distantPast
        return card.transactions
            .filter { tx in
                tx.amount > 0 && tx.id != move.id
                    && !NonFlowMovements.isOwnAccountMove(tx, incoming: true)
                    && tx.date >= from
                    && (tx.date <= move.date || cal.isDate(tx.date, inSameDayAs: move.date))
            }
            .map { Source(id: $0.id, name: $0.name, amount: abs(convert($0)), date: $0.date) }
            .sorted { $0.amount > $1.amount }
    }

    /// The own-account moves in `txs`, one line per other card and direction,
    /// money in first. Moves whose other leg is also in `scope` (the main card
    /// and its bill cards) are left out: inside the pot they cancel out.
    static func lines(_ txs: [TxRecord], scope: [BankCard], cards: [BankCard],
                      convert: (TxRecord) -> Double) -> [Line] {
        let scopeIDs = Set(scope.map(\.id))
        var owner: [UUID: UUID] = [:]
        for card in scope { for tx in card.transactions { owner[tx.id] = card.id } }

        var totals: [String: (incoming: Bool, label: String, amount: Double, sources: [Source])] = [:]
        for tx in txs where tx.txSubtype == .transfer {
            let incoming = tx.amount > 0
            guard NonFlowMovements.isOwnAccountMove(tx, incoming: incoming) else { continue }
            let pair = counterpart(of: tx, ownCardID: owner[tx.id], in: cards)
            if let pair, scopeIDs.contains(pair.card.id) { continue }
            let key = (incoming ? "in:" : "out:") + (pair?.card.id.uuidString ?? tx.name)
            var entry = totals[key] ?? (incoming, pair?.card.pickerLabel ?? tx.name, 0, [])
            entry.amount += abs(convert(tx))
            if incoming, let pair {
                for s in sources(before: pair.tx, on: pair.card, convert: convert)
                where !entry.sources.contains(where: { $0.id == s.id }) {
                    entry.sources.append(s)
                }
            }
            totals[key] = entry
        }
        return totals
            .filter { $0.value.amount >= 0.5 }
            .map { key, e in
                Line(id: key, incoming: e.incoming, label: e.label, amount: e.amount,
                     sources: Array(e.sources.sorted { $0.amount > $1.amount }.prefix(maxSources)))
            }
            .sorted { a, b in a.incoming != b.incoming ? a.incoming : a.amount > b.amount }
    }
}
