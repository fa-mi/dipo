import Foundation
import SwiftData

// MARK: - Turning a recorded row into a loan, or into money paid back
//
// People lend before they think of it as lending. Fahmi wrote "hutang ke
// ibuk", Rp 5.000.000 on 18 August, as an ordinary expense with the note
// "nanti dikembalikan" — and from then on that month read as Rp 5 jt worse
// than it was, while the receivable he added later stood apart from the
// money that actually left. The row and the claim are the same event; this
// joins them after the fact.
//
// Both directions turn the row into a transfer, the same way the Receivables
// screen records a loan or a repayment from the start: lending changes the
// shape of money, not its amount, and a repayment is not new income. Nothing
// is created or deleted in the ledger, so the card balance does not move.
//
// The user's own note is kept. The marker key is only written when the note
// is empty, because the note is often the only record of why ("nanti
// dikembalikan") and the link already says what the row is.

enum ReceivableConversion {

    static let lentNote = "tx.note.receivable_lent"
    static let repaidNote = "tx.note.receivable_repaid"

    // MARK: Which rows qualify

    /// Money out that could be a loan: an ordinary expense, not yet linked to
    /// anything, and not a row the app wrote for a reason of its own — a
    /// recurring bill, a card payment, a goal deposit keep their meaning.
    static func canLend(_ tx: TxRecord) -> Bool {
        tx.amount < 0 && tx.txSubtype == .normal && isFree(tx)
    }

    /// Money in that could be someone paying back what they owe. Income rows
    /// qualify too: a repayment booked as "Other income" is the commonest way
    /// one ends up inflating a month's earnings.
    static func canRepay(_ tx: TxRecord) -> Bool {
        tx.amount > 0 && tx.txSubtype != .refund && tx.category != .salary && isFree(tx)
            && !NonFlowMovements.isOwnAccountMove(tx, incoming: true)
    }

    private static func isFree(_ tx: TxRecord) -> Bool {
        tx.linkedReceivableID.isEmpty && tx.linkedDebtID.isEmpty && tx.linkedGoalID.isEmpty
            && !tx.hasSystemNote && tx.icon != "⇄"
    }

    // MARK: Who it was

    /// Words that say "a loan" or "a transfer" rather than who to. What is
    /// left of the row's name once they're gone is usually the person.
    private static let fillerWords: Set<String> = [
        "hutang", "utang", "ngutang", "pinjam", "pinjaman", "pinjamin", "minjem", "minjam",
        "dipinjamkan", "dipinjam", "ke", "kpd", "kepada", "untuk", "utk", "buat", "bwt",
        "tf", "trf", "transfer", "tranfer", "kirim", "kasih", "uang", "duit", "bayar", "bayarin",
        "lent", "lend", "loan", "to", "for", "money", "sent", "send"
    ]

    /// A first guess at the person's name from the row's name: "hutang ke
    /// ibuk" → "Ibuk", "Cipa Hutang" → "Cipa". Falls back to the whole name
    /// when nothing is left, so the field is never empty.
    static func guessName(from txName: String) -> String {
        let trimmed = txName.trimmingCharacters(in: .whitespacesAndNewlines)
        let kept = trimmed.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "," })
            .map(String.init)
            .filter { !fillerWords.contains($0.lowercased()) && !$0.allSatisfy(\.isNumber) }
        guard let first = kept.first else { return trimmed }
        let joined = ([first.prefix(1).uppercased() + first.dropFirst()] + kept.dropFirst())
            .joined(separator: " ")
        return joined
    }

    /// The open receivable the row most likely belongs to, by name — so the
    /// common case is one tap. nil when no name lines up.
    static func likelyMatch(for txName: String, in open: [Receivable]) -> Receivable? {
        let words = Set(txName.lowercased().split(separator: " ").map(String.init))
        return open.first { r in
            let name = r.personName.lowercased().trimmingCharacters(in: .whitespaces)
            // Whole words always; inside a longer word only from three
            // letters up, so "Al" doesn't claim every row with an "al" in it.
            return !name.isEmpty
                && (words.contains(name) || (name.count >= 3 && txName.lowercased().contains(name)))
        }
    }

    // MARK: Lending

    /// Whether attaching this row to `receivable` should also raise what is
    /// owed. A row from before the receivable was written down is most likely
    /// already inside its amount — people add the claim after the fact, with
    /// the total they remember. A row from after it is more lending.
    static func addsToAmountByDefault(_ tx: TxRecord, receivable: Receivable) -> Bool {
        tx.date >= receivable.createdAt
    }

    /// A new receivable for the whole row, dated when the money left.
    @discardableResult
    static func lendNew(_ tx: TxRecord, personName: String, context: ModelContext) -> Receivable {
        let name = personName.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = Receivable(personName: name.isEmpty ? guessName(from: tx.name) : name,
                           amount: abs(tx.amount),
                           currency: tx.currency.isEmpty ? CurrencyManager.shared.preferredCurrency : tx.currency,
                           lentAt: tx.date)
        context.insert(r)
        markLent(tx, to: r)
        return r
    }

    /// Joins the row to a claim that already exists. `addToAmount` raises
    /// what is owed by the row; off, the row is taken to be part of the
    /// amount already written down. Either way the claim now dates from the
    /// earliest money that left.
    static func lendAttach(_ tx: TxRecord, to r: Receivable, addToAmount: Bool) {
        if addToAmount {
            r.amount += CurrencyManager.shared.convert(abs(tx.amount),
                                                       from: tx.currency.isEmpty ? r.currency : tx.currency,
                                                       to: r.currency)
            r.isSettled = false
        }
        if tx.date < r.lentAt { r.lentAt = tx.date }
        markLent(tx, to: r)
    }

    private static func markLent(_ tx: TxRecord, to r: Receivable) {
        tx.txSubtype = .transfer
        tx.linkedReceivableID = r.id.uuidString
        if tx.notes.trimmingCharacters(in: .whitespaces).isEmpty { tx.notes = lentNote }
    }

    // MARK: Paying back

    /// Books the row as a repayment and settles the claim when nothing is
    /// left — the same rule the repayment sheet uses. `allTx` is every row,
    /// so repayments on other cards count too.
    static func repay(_ tx: TxRecord, to r: Receivable, allTx: [TxRecord]) {
        tx.txSubtype = .transfer
        tx.linkedReceivableID = r.id.uuidString
        if tx.notes.trimmingCharacters(in: .whitespaces).isEmpty { tx.notes = repaidNote }
        let rows = allTx.contains(where: { $0.id == tx.id }) ? allTx : allTx + [tx]
        if r.outstanding(from: rows) <= 0.01 { r.isSettled = true }
    }

    // MARK: Undoing

    /// Takes the row back to an ordinary expense or income. A claim that was
    /// made from this row alone — nothing else linked, same amount, same day
    /// — goes with it; any other claim stays, its amount untouched, because
    /// DiPo cannot know whether the row was ever counted in it.
    /// Returns true when the claim was removed.
    @discardableResult
    static func unlink(_ tx: TxRecord, receivables: [Receivable], allTx: [TxRecord],
                       context: ModelContext) -> Bool {
        let key = tx.linkedReceivableID
        guard !key.isEmpty else { return false }
        let wasLoan = tx.amount < 0
        tx.linkedReceivableID = ""
        tx.txSubtype = .normal
        if tx.notes == lentNote || tx.notes == repaidNote { tx.notes = "" }

        guard let r = receivables.first(where: { $0.id.uuidString == key }) else { return false }
        let othersLinked = allTx.contains { $0.id != tx.id && $0.linkedReceivableID == key }
        if wasLoan, !othersLinked,
           abs(r.amount - abs(tx.amount)) < 0.5,
           Calendar.current.isDate(r.lentAt, inSameDayAs: tx.date) {
            context.delete(r)
            return true
        }
        if !wasLoan, r.isSettled {
            let rest = allTx.filter { $0.id != tx.id }
            if r.outstanding(from: rest) > 0.01 { r.isSettled = false }
        }
        return false
    }
}
