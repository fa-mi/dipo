import SwiftUI

// MARK: - BankCard Computed Helpers
// Extracted from the views that were duplicating this logic independently.

extension BankCard {

    // MARK: - Display Helpers

    /// Formatted card number with spaces every 4 digits.
    /// e.g. "1234567812345678" → "1234 5678 1234 5678"
    var formattedNumber: String {
        let digits = cardNumber.replacingOccurrences(of: " ", with: "").prefix(CardNetwork.maxLength)
        var result = ""
        for (i, ch) in digits.enumerated() {
            if i > 0 && i % 4 == 0 { result += " " }
            result += String(ch)
        }
        return result.isEmpty ? "•••• •••• •••• ••••" : result
    }

    /// Card number shown in the UI, respecting this card's individual hide/show state.
    /// Hidden  → "•••• •••• •••• ••••"
    /// Visible → full formatted number
    var displayNumber: String {
        isHidden ? "•••• •••• •••• ••••" : formattedNumber
    }

    /// How a transfer's two legs name the other card: "Transfer to •••• 0969",
    /// "Transfer from GoPay". Written into the rows' names, by the transfer
    /// form and by the review queue's "Record as a transfer".
    var transferLabel: String {
        if isDigitalWallet, !walletProvider.isEmpty { return walletProvider }
        let l4 = last4
        return l4.isEmpty ? (holderName.isEmpty ? loc("transfer.card") : holderName) : "•••• \(l4)"
    }

    /// Compact one-line name for choosers ("BRI ·· 0969", "GoPay"). Wallets show
    /// their provider; cards show the holder name plus the last four digits so
    /// two cards from the same bank stay distinguishable.
    var pickerLabel: String {
        let last4 = String(cardNumber.filter(\.isNumber).suffix(4))
        let name = isDigitalWallet && !walletProvider.isEmpty ? walletProvider : holderName
        if name.isEmpty { return last4.isEmpty ? loc("card.untitled") : "·· \(last4)" }
        return last4.isEmpty ? name : "\(name) ·· \(last4)"
    }

    /// What tells this card from the user's others, without its digits.
    ///
    /// A wallet goes by its provider and a card by the bank chosen for it. A
    /// card with no bank chosen goes by its own name less the leading words
    /// it shares with another card: people write the bank into the name, so
    /// "Fahmi Aquinas BRI", "Fahmi Aquinas BCA" and "Fahmi Aquinas Mandiri"
    /// read as BRI, BCA and Mandiri, where `pickerLabel` repeated the holder
    /// on each. Nothing is guessed: a name that is all shared stays whole,
    /// and the last four digits tell those apart.
    func distinctName(among cards: [BankCard]) -> String {
        if isDigitalWallet { return walletProvider.isEmpty ? loc("wallet.untitled") : walletProvider }
        if let bank = BankIssuer.find(issuerID)?.name { return bank }
        let words = holderName.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return loc("wallet.untitled") }
        let shared = cards
            .filter { $0.id != id && !$0.isDigitalWallet }
            .map { other in
                zip(words, other.holderName.split(whereSeparator: \.isWhitespace))
                    .prefix(while: { $0.lowercased() == $1.lowercased() }).count
            }
            .max() ?? 0
        return (shared < words.count ? words.dropFirst(shared) : words[...]).joined(separator: " ")
    }

    /// `distinctName` and the last four digits: "BCA ••9331", "GoPay".
    func shortName(among cards: [BankCard]) -> String {
        let name = distinctName(among: cards)
        let last4 = String(cardNumber.filter(\.isNumber).suffix(4))
        return isDigitalWallet || last4.count < 4 ? name : "\(name) ••\(last4)"
    }

    /// Phone number shown in the UI, respecting this card's individual hide/show state.
    /// Hidden  → "•••••••• 7890"  (last 4 always visible for wallet identification)
    /// Visible → full phone number
    var displayPhone: String {
        if isHidden {
            let stripped = phoneNumber.replacingOccurrences(of: " ", with: "")
            guard stripped.count > 4 else { return phoneNumber }
            let hidden = String(repeating: "•", count: min(stripped.count - 4, 8))
            return hidden + " " + String(stripped.suffix(4))
        }
        return phoneNumber
    }

    // MARK: - Kept for backward-compat (used in delete dialog last-4 suffix)
    var last4: String { String(cardNumber.replacingOccurrences(of: " ", with: "").suffix(4)) }

    /// The card's own currency, falling back to the user's preferred currency.
    /// Replaces the repeated inline ternary:
    ///   `card.currency.isEmpty ? CurrencyManager.shared.preferredCurrency : card.currency`
    var resolvedCurrency: String {
        currency.isEmpty ? CurrencyManager.shared.preferredCurrency : currency
    }

    // MARK: - Balance

    /// Sum of all transactions converted into the card's own currency.
    func liveTransactionBalance() -> Double {
        transactions.reduce(0.0) { sum, tx in
            sum + CurrencyManager.shared.convert(tx.amount, from: tx.currency, to: resolvedCurrency)
        }
    }

    /// Total balance (seed + all transactions) in the card's own currency.
    func computedBalance() -> Double {
        balance + liveTransactionBalance()
    }

    // MARK: - Credit card math
    //
    // For a credit card, "balance" isn't cash you have — it's what you OWE.
    // owed = openingOwed − Σ(transactions since creditSince) + instalments
    // billed since. A purchase (amount < 0) raises owed; a payment (amount > 0,
    // from a transfer) lowers it. Only transactions on/after `creditSince`
    // count, so converting a card with history doesn't retroactively
    // recompute the debt. See `bill(_:asOf:)` for the split.

    /// What paying this credit card off today would take, in its own currency:
    /// purchases and the opening balance, plus instalments billed and not yet
    /// paid. Instalment principal not billed yet is not in it — that is
    /// `totalOwed(_:)`. Clamped at 0 — overpaying leaves a zero balance, not a
    /// negative "debt".
    func owedBalance() -> Double {
        guard isCreditCard else { return 0 }
        return bill().bill
    }

    /// Credit still available to spend, never below 0: the limit less the
    /// whole debt, instalment principal not billed yet included — it holds
    /// the limit though it is on no bill. Taking only the bill off said
    /// Rp 34 jt was free on a card whose Debts row said Rp 24 jt.
    func availableCredit() -> Double {
        guard isCreditCard else { return 0 }
        return max(creditLimit - bill().total, 0)
    }

    /// Sets what the card owes as of now, from its edit form — when the
    /// figure the form showed was changed. Saving the form unchanged, to
    /// rename the card say, re-based the card on that figure anyway, and it
    /// can't hold money paid beyond the bill: the Rp 250.000 overpaid on a
    /// Tokopedia CC was dropped, and the card read Rp 10.250.000 owed again.
    func setOwed(_ owed: Double, shown: Double, at date: Date = .now) {
        guard abs(owed - shown) >= 0.5 else { return }
        openingOwed = owed
        creditSince = date
    }

    /// Fraction of the limit used, 0…1 (for a usage bar), on the same total.
    var creditUtilization: Double {
        guard isCreditCard, creditLimit > 0 else { return 0 }
        return min(bill().total / creditLimit, 1)
    }

    /// Formatted owed amount.
    var formattedOwed: String {
        CurrencyManager.shared.formatted(owedBalance(), currency: resolvedCurrency)
    }
    /// Formatted available credit.
    var formattedAvailable: String {
        CurrencyManager.shared.formatted(availableCredit(), currency: resolvedCurrency)
    }

    /// Formatted total balance including a leading "-" when negative.
    var formattedBalance: String {
        let total = computedBalance()
        let absValue = Swift.abs(total)
        return (total < 0 ? "-" : "") + CurrencyManager.shared.formatted(absValue, currency: resolvedCurrency)
    }

    // MARK: - Cross-Card Total (fixes currency-conversion bug)
    // The old `formattedTotalAllCards(_:)` helper in CardListView summed raw
    // transaction amounts across cards without converting currencies first.
    // This static method converts every card's balance to the user's preferred
    // currency before summing, giving the correct multi-currency total.
    static func totalBalanceAcrossCards(
        _ cards: [BankCard],
        preferredCurrency: String = CurrencyManager.shared.preferredCurrency
    ) -> Double {
        let mgr = CurrencyManager.shared
        return cards.reduce(0.0) { sum, card in
            let cardTotal = card.computedBalance()
            return sum + mgr.convert(cardTotal, from: card.resolvedCurrency, to: preferredCurrency)
        }
    }

    // MARK: - Expiry Helpers
    // expireDate is stored as "MM/YY" (e.g. "02/29").
    // All helpers return nil gracefully if the format is unexpected.

    /// Parses "MM/YY" into the last day of that month.
    var expiryDate: Date? {
        let parts = expireDate.split(separator: "/")
        guard parts.count == 2,
              let month = Int(parts[0]),
              let year2 = Int(parts[1]) else { return nil }
        let fullYear = 2000 + year2
        var comps = DateComponents(year: fullYear, month: month)
        // Move to first of next month, subtract 1 day → last day of expiry month
        guard let firstOfNext = Calendar.current.date(from: comps) else { return nil }
        comps.month = month + 1
        comps.day   = 0
        return Calendar.current.date(from:
            DateComponents(year: fullYear, month: month + 1, day: 0)) ?? firstOfNext
    }

    /// Days remaining until expiry. Negative = already expired.
    var daysUntilExpiry: Int? {
        guard let exp = expiryDate else { return nil }
        return Calendar.current.dateComponents([.day], from: .now, to: exp).day
    }

    var isExpired:      Bool { (daysUntilExpiry ?? 1) < 0 }
    var expiresSoon:    Bool { (daysUntilExpiry ?? 999) <= 30 && !isExpired }
    var expiresUrgent:  Bool { (daysUntilExpiry ?? 999) <= 7  && !isExpired }

    /// Human-readable status for UI badges.
    var expiryStatus: CardExpiryStatus {
        guard let days = daysUntilExpiry else { return .ok }
        if days < 0  { return .expired }
        if days <= 7 { return .urgent }
        if days <= 30 { return .soon }
        return .ok
    }

}

// MARK: - Card Expiry Status

enum CardExpiryStatus {
    case ok, soon, urgent, expired

    var label: String {
        switch self {
        case .ok:      return ""
        case .soon:    return "Expires soon"
        case .urgent:  return "Expires this week"
        case .expired: return "Expired"
        }
    }

    var color: Color {
        switch self {
        case .ok:      return .clear
        case .soon:    return AppTheme.orange   // orange
        case .urgent:  return AppTheme.red
        case .expired: return AppTheme.red
        }
    }

    var icon: String {
        switch self {
        case .ok:      return ""
        case .soon:    return "exclamationmark.circle"
        case .urgent:  return "exclamationmark.triangle.fill"
        case .expired: return "xmark.circle.fill"
        }
    }
}
