import Foundation
import SwiftData

// MARK: - A bill paid by hand before DiPo records it
//
// RecurringDuplicates finds a double-log after the fact. This stops one before
// it is written: when a bill falls due and the same amount already left the
// same card by hand in the same pay period, DiPo does not record the bill. It
// puts it in the Pending inbox with the hand-entered row named beside it, and
// the user decides — submit it if it was a separate payment, swipe it away if
// it was the same one.
//
// It never decides on its own. Two transfers of the same amount to the same
// person in one month are often both real — a monthly allowance and a one-off
// need — and skipping either would be a wrong balance with no trace of why.

enum RecurringManualMatch {

    /// How far before the due date a hand-entered payment still counts as the
    /// bill paid early, when the pay period alone would open later. Without a
    /// salary the period is the calendar month, and a bill due on the 1st is
    /// often paid on the 28th.
    static let earlyDays = 7

    /// Whether `tx` could be this bill under another name. Fixed-cost rows, the
    /// bill's own category and "Other" — where an ad-hoc transfer usually lands
    /// — qualify on the amount. A day-to-day row qualifies only if it shares a
    /// word with the bill: a Rp 55.000 lunch is not the parking bill.
    static func couldBe(_ tx: TxRecord, planLabel: String, planCategory: TxCategory) -> Bool {
        if tx.category == planCategory || tx.category == .other
            || SmartBudgetManager.fixedCategories.contains(tx.category) { return true }
        return sharesWord(tx.name, planLabel)
    }

    static func words(_ s: String) -> Set<String> {
        Set(SmartBudgetManager.normalizedMerchant(s).split(separator: " ")
            .map(String.init).filter { $0.count >= 3 })
    }

    static func sharesWord(_ a: String, _ b: String) -> Bool {
        !words(a).isDisjoint(with: words(b))
    }

    /// Where to start looking for a bill due on `due`: the start of its pay
    /// period or a week before it, whichever is earlier — but never at or
    /// before the bill's previous recorded charge, which belongs to last month.
    static func windowStart(due: Date, periodStart: Date, previousCharge: Date?,
                            cal: Calendar = .current) -> Date {
        let early = cal.date(byAdding: .day, value: -earlyDays, to: cal.startOfDay(for: due)) ?? due
        var start = min(periodStart, early)
        if let last = previousCharge { start = max(start, last.addingTimeInterval(1)) }
        return start
    }

    /// The hand-entered expense that may already be this charge — same card,
    /// same amount (within 1 %, or Rp 1.000), in the window — nearest the due
    /// date. `amount` is positive, in `currency`.
    static func find(amount: Double, currency: String, planLabel: String, planCategory: TxCategory,
                     due: Date, from start: Date, to end: Date,
                     in transactions: [TxRecord], excluding: Set<UUID> = []) -> TxRecord? {
        guard amount > 0 else { return nil }
        let cm = CurrencyManager.shared
        let tolerance = max(amount * 0.01, currency == "IDR" ? 1_000 : 0.01)
        return transactions.filter { (tx: TxRecord) -> Bool in
            guard tx.amount < 0, tx.txSubtype != .transfer,
                  tx.notes != "tx.note.recurring_auto",
                  !excluding.contains(tx.id),
                  tx.date >= start, tx.date <= end else { return false }
            let v = cm.convert(abs(tx.amount), from: tx.currency.isEmpty ? currency : tx.currency, to: currency)
            guard abs(v - amount) <= tolerance else { return false }
            return couldBe(tx, planLabel: planLabel, planCategory: planCategory)
        }
        .min { abs($0.date.timeIntervalSince(due)) < abs($1.date.timeIntervalSince(due)) }
    }

    /// The row a held charge was matched against, if it still exists. The
    /// pending row keeps only its id: names and amounts are read live, so the
    /// note never quotes a row the user has since edited.
    @MainActor
    static func matchedRow(for item: PendingTransaction, context: ModelContext) -> TxRecord? {
        guard item.source == .recurring, let id = UUID(uuidString: item.rawText) else { return nil }
        var d = FetchDescriptor<TxRecord>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    /// What the inbox says under a held bill: which hand-entered row it
    /// matched, and what each gesture means.
    @MainActor
    static func holdNote(for item: PendingTransaction, context: ModelContext) -> String {
        guard let tx = matchedRow(for: item, context: context) else { return loc("pending.recurring_gone") }
        let f = DateFormatter()
        f.locale = LanguageManager.shared.currentLocale
        f.setLocalizedDateFormatFromTemplate("EEE d MMM")
        let amount = CurrencyManager.shared.formatted(abs(tx.amount),
                                                      currency: tx.currency.isEmpty ? item.currency : tx.currency)
        return String(format: loc("pending.recurring_note"), tx.name, amount, f.string(from: tx.date))
    }
}
