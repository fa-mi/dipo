import SwiftUI

// MARK: - BankCard Computed Helpers
// Extracted from the views that were duplicating this logic independently.

extension BankCard {

    // MARK: - Display Helpers

    /// Formatted card number with spaces every 4 digits.
    /// e.g. "1234567812345678" → "1234 5678 1234 5678"
    var formattedNumber: String {
        let digits = cardNumber.replacingOccurrences(of: " ", with: "").prefix(16)
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
        case .soon:    return Color(hex: "#FB923C")   // orange
        case .urgent:  return Color(hex: "#FF5B5B")   // red
        case .expired: return Color(hex: "#FF5B5B")   // red
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
