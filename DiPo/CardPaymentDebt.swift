import Foundation
import SwiftData

// MARK: - When a credit-card payment is paying off debt
//
// A card bill payment was recorded as a plain transfer: the purchases were
// already counted as spending when they were made on the card, so counting
// the payment too would count them twice. That is right for a bill made of
// this month's and last month's purchases.
//
// It is wrong for a balance carried from before — an opening balance owed
// when the card was added, or purchases from months ago never paid off. That
// is debt, and paying it down is a debt payment like any other: it belongs in
// Invest & Debt, where Smart Budget and the advice look for it. Leaving it a
// transfer showed "Invest & Debt Rp 0" to someone who had just paid Rp 2 jt
// off an Rp 11 jt card balance.
//
// So a payment is split: the part covering the carried balance is recorded
// as a debt payment, the part covering recent purchases stays a transfer.
// "Recent" is the window FinancialLadder uses — this month and last.

enum CardPaymentDebt {

    /// How much of `payment` pays down debt rather than recent purchases.
    static func debtPortion(payment: Double, owedBefore: Double, recentCharges: Double) -> Double {
        min(max(payment, 0), FinancialLadder.carriedOver(owed: owedBefore, recentCharges: recentCharges))
    }

    /// What the card owed just before `date`, in the card's currency: the
    /// opening balance moved by every transaction since the card became a
    /// credit card. Mirrors `BankCard.owedBalance()` at a point in time.
    static func owedBefore(openingOwed: Double, since: Date?, transactions: [TxRecord],
                           date: Date, convert: (TxRecord) -> Double) -> Double {
        let from = since ?? .distantPast
        let movement = transactions
            .filter { $0.date >= from && $0.date < date }
            .reduce(0.0) { $0 + convert($1) }
        return max(openingOwed - movement, 0)
    }

    /// Purchases on the card from the start of the month before `date` up to
    /// it: the bill a payment is normally settling.
    static func recentCharges(transactions: [TxRecord], before date: Date,
                              convert: (TxRecord) -> Double, cal: Calendar = .current) -> Double {
        let month = cal.date(from: cal.dateComponents([.year, .month], from: date)) ?? date
        let start = cal.date(byAdding: .month, value: -1, to: month) ?? month
        return transactions
            .filter { $0.date >= start && $0.date < date && $0.amount < 0 && $0.txSubtype != .transfer }
            .reduce(0.0) { $0 + abs(convert($1)) }
    }

    // MARK: Payments recorded before this

    private static let doneKey = "cardPaymentDebt.reclassified.v1"

    /// Once: re-file the debt part of earlier card payments, which were all
    /// recorded as transfers. A payment wholly against the carried balance is
    /// re-categorised in place; one that was partly that is split in two.
    @MainActor
    static func reclassifyPastPayments(cards: [BankCard], context: ModelContext) {
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }
        let cm = CurrencyManager.shared
        let creditCards = cards.filter(\.isCreditCard)
        guard !creditCards.isEmpty else {
            UserDefaults.standard.set(true, forKey: doneKey)
            return
        }
        var changed = false
        for source in cards where !source.isCreditCard {
            for out in source.transactions
            where out.notes == "tx.note.cc_payment" && out.amount < 0
                && out.txSubtype == .transfer && out.category == .other {
                // The card side of the same payment: same note, written a
                // moment later, for the same amount in the card's currency.
                guard let match = creditCards.lazy.compactMap({ card -> (BankCard, TxRecord)? in
                    let paid = cm.convert(abs(out.amount), from: out.currency, to: card.resolvedCurrency)
                    guard let leg = card.transactions.first(where: {
                        $0.notes == "tx.note.cc_payment" && $0.amount > 0
                            && abs($0.date.timeIntervalSince(out.date)) < 120
                            && abs($0.amount - paid) < max(1, paid * 0.01)
                    }) else { return nil }
                    return (card, leg)
                }).first else { continue }
                let (card, credit) = match

                let inCard = { (tx: TxRecord) in cm.convert(tx.amount, from: tx.currency, to: card.resolvedCurrency) }
                let cutoff = min(out.date, credit.date)
                let owed = owedBefore(openingOwed: card.openingOwed, since: card.creditSince,
                                      transactions: card.transactions, date: cutoff, convert: inCard)
                let recent = recentCharges(transactions: card.transactions, before: cutoff, convert: inCard)
                let debtInCard = debtPortion(payment: credit.amount, owedBefore: owed, recentCharges: recent)
                guard debtInCard >= 1 else { continue }
                let debt = min(cm.convert(debtInCard, from: card.resolvedCurrency, to: out.currency),
                               abs(out.amount))

                if abs(out.amount) - debt < 1 {
                    out.category = .debtPayment
                    out.txSubtype = .normal
                } else {
                    out.amount = -(abs(out.amount) - debt)
                    let split = TxRecord(name: out.name, date: out.date, amount: -debt, type: out.type,
                                         icon: out.icon, iconBgHex: TxCategory.debtPayment.iconBg,
                                         category: .debtPayment, currency: out.currency,
                                         notes: "tx.note.cc_payment", subtype: .normal)
                    context.insert(split)
                    source.transactions.append(split)
                }
                changed = true
            }
        }
        UserDefaults.standard.set(true, forKey: doneKey)
        guard changed else { return }
        try? context.save()
        // The rollup cache only notices a change in transaction COUNT; a
        // re-categorised payment keeps it.
        RollupStore.shared.rebuild(context: context)
    }
}
