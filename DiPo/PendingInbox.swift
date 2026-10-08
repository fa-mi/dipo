import SwiftUI
import SwiftData

// MARK: - Pending transactions
//
// Everything DiPo reads for you rather than from you lands here first, and
// nothing reaches the ledger until you have seen it. A parser that is right
// nine times out of ten is useful; one that writes straight into the ledger is
// a liability, because the tenth entry is a wrong number in your balance and
// you have no idea where it came from.
//
// So: captured in the background, reviewed on the next open. Swipe away what is
// not yours, correct what was misread — a merchant name, the card it came out
// of — and submit the rest in one go.
//
// This is the destination. What fills it (a Shortcuts automation on a bank SMS,
// the Back Tap screenshot, a scanned receipt) plugs in through `capture`.

@Model
final class PendingTransaction {
    var id: UUID
    /// When DiPo read it, not when the money moved — `date` is that.
    var capturedAt: Date
    var sourceRaw: String

    /// What was read, kept verbatim. The editor shows it under the fields so a
    /// wrong guess can be checked against the words it came from, and a parser
    /// bug can be diagnosed from a real example instead of a description.
    var rawText: String

    var name: String
    /// Signed, as in `TxRecord`: negative is money out.
    var amount: Double
    var currency: String
    var date: Date
    var categoryRaw: String
    /// The card this belongs to. Nil when the source did not say, which is the
    /// single most common thing to correct.
    var cardID: UUID?

    init(name: String, amount: Double, currency: String, date: Date = .now,
         category: TxCategory = .other, cardID: UUID? = nil,
         source: PendingSource = .manual, rawText: String = "") {
        self.id = UUID()
        self.capturedAt = .now
        self.sourceRaw = source.rawValue
        self.rawText = rawText
        self.name = name
        self.amount = amount
        self.currency = currency
        self.date = date
        self.categoryRaw = category.rawValue
        self.cardID = cardID
    }

    var source: PendingSource { PendingSource(rawValue: sourceRaw) ?? .manual }
    var category: TxCategory {
        get { TxCategory(rawValue: categoryRaw) ?? .other }
        set { categoryRaw = newValue.rawValue }
    }
    var isExpense: Bool { amount < 0 }
}

/// Where a pending row came from. Shown on the row, because how something was
/// read is part of how much you should trust it.
enum PendingSource: String, CaseIterable {
    case shortcut   // a Shortcuts automation handed over a bank SMS or email
    case backTap    // the Back Tap screenshot flow
    case scan       // a scanned receipt
    case manual
    /// A bill that fell due while a hand-entered row of the same amount was
    /// already in its period — held here instead of being recorded twice.
    /// `rawText` holds that row's id (see RecurringManualMatch).
    case recurring

    var icon: String {
        switch self {
        case .shortcut: return "bolt.horizontal.circle.fill"
        case .backTap:  return "iphone.gen3.badge.play"
        case .scan:     return "doc.text.viewfinder"
        case .manual:   return "square.and.pencil"
        case .recurring: return "repeat.circle.fill"
        }
    }

    var labelKey: String {
        switch self {
        case .shortcut: return "pending.source.shortcut"
        case .backTap:  return "pending.source.backtap"
        case .scan:     return "pending.source.scan"
        case .manual:   return "pending.source.manual"
        case .recurring: return "pending.source.recurring"
        }
    }
}

// MARK: - The two operations that matter

enum PendingInbox {

    /// Put a read transaction in the queue. Never writes to the ledger.
    @MainActor
    @discardableResult
    static func capture(name: String, amount: Double, currency: String,
                        date: Date = .now, category: TxCategory = .other,
                        cardID: UUID? = nil, source: PendingSource,
                        rawText: String = "", context: ModelContext) -> PendingTransaction {
        let item = PendingTransaction(name: name, amount: amount, currency: currency,
                                      date: date, category: category, cardID: cardID,
                                      source: source, rawText: rawText)
        context.insert(item)
        try? context.save()
        return item
    }

    /// Turn a reviewed row into a real transaction on its card.
    ///
    /// Returns false when there is no card to put it on — the one thing that
    /// cannot be guessed. The row stays in the queue in that case rather than
    /// vanishing into nowhere.
    @MainActor
    @discardableResult
    static func commit(_ item: PendingTransaction, cards: [BankCard],
                       context: ModelContext) -> Bool {
        guard let cardID = item.cardID,
              let card = cards.first(where: { $0.id == cardID }) else { return false }

        let tx = TxRecord(
            name: item.name,
            date: item.date,
            amount: item.amount,
            // Stable keys, never `loc(...)` output: a stored translation would
            // freeze the language at the moment of capture.
            type: item.isExpense ? "tx.type.purchase" : "tx.type.income",
            icon: String(item.name.prefix(2)).uppercased(),
            iconBgHex: item.category.iconBg,
            category: item.category,
            currency: item.currency,
            // A held bill becomes the bill's own charge, so everything that
            // recognises recorded bills (due status, duplicates, projection)
            // sees it as one.
            notes: item.source == .recurring ? "tx.note.recurring_auto" : "tx.note.from_inbox"
        )
        // Insert before appending: `transactions` has no inverse, so a child
        // added only through the parent's array is not reliably persisted.
        context.insert(tx)
        card.transactions.append(tx)
        context.delete(item)
        return true
    }
}
