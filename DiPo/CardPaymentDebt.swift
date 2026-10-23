import Foundation
import SwiftData

// MARK: - When a credit-card payment is paying off debt
//
// A card bill payment was recorded as a plain transfer: the purchases were
// already counted as spending when they were made on the card, so counting
// the payment too would count them twice. That is right for the part of a
// payment that covers purchases logged in DiPo.
//
// It is wrong for debt that was never counted as spending — the balance owed
// when the card was added, and instalments, whose purchase is not a
// transaction at all. Paying those down is a debt payment like any other: it
// belongs in Savings & debt, where Smart Budget and the advice look for it.
//
// So a payment is split, and the order it settles things in decides how:
// instalments billed and not yet paid first, then purchases logged in DiPo,
// oldest first, then the older balance. The first and the last are debt
// payments; the purchases are a transfer.
//
// Purchases come before the older balance on purpose. The rule used to be the
// other way round — what the card owed beyond this month's and last month's
// purchases was "carried", and paid first — so every purchase not paid within
// two months turned into carried debt, and was counted again as a debt
// payment when it was finally paid: once in Needs or Wants when it was
// bought, once in Savings & debt. A Rp 1,5 jt payment against a card with
// Rp 500 rb of this month's purchases counted Rp 1,5 jt of debt paid when the
// debt had gone down by Rp 1 jt.

enum CardPaymentDebt {

    /// How a payment divides, in the card's currency.
    struct Split: Equatable {
        /// Instalments billed and the older balance: counted as a debt payment.
        let debt: Double
        /// Purchases already counted as spending when they were made.
        let purchases: Double
        /// Paid beyond everything owed: it stays on the card as credit.
        let extra: Double
    }

    /// Splits `payment`: billed instalments first, then purchases, then the
    /// older balance; anything beyond them is extra.
    static func split(payment: Double, installmentDue: Double, unpaidPurchases: Double,
                      olderBalance: Double) -> Split {
        let paid = max(payment, 0)
        let instalments = min(paid, max(installmentDue, 0))
        let purchases = min(paid - instalments, max(unpaidPurchases, 0))
        let older = min(paid - instalments - purchases, max(olderBalance, 0))
        return Split(debt: instalments + older, purchases: purchases,
                     extra: paid - instalments - purchases - older)
    }

    /// How `payment`, in the card's currency, would split if it were recorded
    /// on `card` now — or at `date`, with the ledger as it stood then.
    static func split(payment: Double, on card: BankCard, installments: [CardInstallment]? = nil,
                      asOf date: Date? = nil) -> Split {
        let bill = card.bill(installments, asOf: date)
        let unpaid = unpaidPurchases(on: card, installments: installments, asOf: date)
        return split(payment: payment, installmentDue: bill.installmentDue,
                     unpaidPurchases: unpaid, olderBalance: bill.revolving - unpaid)
    }

    /// Purchases logged on `card` and not paid off yet, in the card's currency —
    /// the part of its balance already counted as spending. The rest of the
    /// balance, besides billed instalments, is the older balance.
    ///
    /// Replays the card's ledger in date order under the rule `split` uses.
    /// Credits fill billed instalments first, in total, exactly as `bill()`
    /// counts them; what is left of each credit pays purchases made before it.
    /// A refund takes its purchase back. A charge that is not a purchase — a
    /// cash withdrawal moved to another account — was never spending, so it
    /// is part of the older balance.
    static func unpaidPurchases(on card: BankCard, installments: [CardInstallment]? = nil,
                                asOf date: Date? = nil) -> Double {
        guard card.isCreditCard else { return 0 }
        let cm = CurrencyManager.shared
        let since = card.creditSince ?? .distantPast
        let asOf = date ?? .now
        let mine = (installments ?? card.storedInstallments).filter { $0.cardID == card.id && $0.isActive }
        var instalmentRoom = mine.reduce(0.0) {
            $0 + cm.convert($1.billed(after: max($1.createdAt, since), upTo: asOf),
                            from: $1.currency, to: card.resolvedCurrency)
        }
        let rows = card.transactions
            .filter { $0.date >= since && (date == nil || $0.date <= asOf) }
            .sorted { $0.date < $1.date }
        var purchases = 0.0
        for tx in rows {
            let v = cm.convert(tx.amount, from: tx.currency, to: card.resolvedCurrency)
            if v < 0 {
                if tx.txSubtype == .normal { purchases -= v }
            } else if tx.txSubtype == .refund {
                purchases = max(purchases - v, 0)
            } else {
                let toInstalments = min(v, instalmentRoom)
                instalmentRoom -= toInstalments
                purchases = max(purchases - (v - toInstalments), 0)
            }
        }
        return min(purchases, card.bill(installments, asOf: date).revolving)
    }

    // MARK: Payments recorded before this

    private static let doneKey = "cardPaymentDebt.reclassified.v1"

    /// Once: re-file the debt part of earlier card payments, which were all
    /// recorded as transfers, under the rule `split` uses. A payment that was
    /// all debt is re-categorised in place; one that was partly debt is split
    /// in two.
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

                // Under today's rule, with the card's ledger as it stood just
                // before this payment: its own leg is written a moment after
                // the cash side, so it is not yet in it.
                let paid = credit.currency.isEmpty ? credit.amount
                    : cm.convert(credit.amount, from: credit.currency, to: card.resolvedCurrency)
                let debtInCard = Self.split(payment: paid, on: card, asOf: min(out.date, credit.date)).debt
                guard debtInCard >= 1 else { continue }
                let debt = min(cm.convert(debtInCard, from: card.resolvedCurrency, to: out.currency),
                               abs(out.amount))

                if abs(out.amount) - debt < 1 {
                    out.category = .debtPayment
                    out.txSubtype = .normal
                } else {
                    out.amount = -(abs(out.amount) - debt)
                    let debtRow = TxRecord(name: out.name, date: out.date, amount: -debt, type: out.type,
                                           icon: out.icon, iconBgHex: TxCategory.debtPayment.iconBg,
                                           category: .debtPayment, currency: out.currency,
                                           notes: "tx.note.cc_payment", subtype: .normal)
                    context.insert(debtRow)
                    source.transactions.append(debtRow)
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
