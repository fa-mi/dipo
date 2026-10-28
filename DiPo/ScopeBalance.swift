import Foundation

// MARK: - What the Statistics balance adds up
//
// With the cards the main card pays bills from in its pot, the balance on
// Statistics sums all of them, and it was labelled "Main card balance now":
// Rp 10.587.000 there, against Rp 7.686.000 on the main card on Home. The
// figure was right and the words were not. They now say how many cards it
// adds up, and under the cash book's total, each card's part, so it can be
// checked against Home card by card.

enum ScopeBalance {
    /// The headline over the balance: the main card's, or the pot's.
    static func nowLabel(cards: Int) -> String {
        cards > 1 ? String(format: loc("stats.balance_now_cards"), cards) : loc("stats.balance_now")
    }

    /// The cash book's last line, the same balance.
    static func todayLabel(cards: Int) -> String {
        cards > 1 ? String(format: loc("stats.balance_today_cards"), cards) : loc("stats.card_balance_now")
    }

    /// "BRI ••0969 Rp 7.686.000 · BCA ••9331 Rp 1.900.000", in `currency`.
    /// Nil for a pot of one card: its balance is the figure itself.
    static func split(_ cards: [BankCard], among all: [BankCard], currency: String) -> String? {
        guard cards.count > 1 else { return nil }
        let cm = CurrencyManager.shared
        return cards.map { card in
            let v = cm.convert(card.computedBalance(), from: card.resolvedCurrency, to: currency)
            return card.shortName(among: all) + " " + (v < -0.5 ? "−" : "") + cm.formatted(abs(v), currency: currency)
        }.joined(separator: " · ")
    }
}
