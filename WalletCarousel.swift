import SwiftUI

// MARK: - A card as an icon
//
// The card in the transfer sheet, standing up: small enough that it only has
// to say which card it is, so it carries the bank and the principal and no
// figures. The cards in the wallet lie down in their pocket (WalletPocket.swift).
//
// The words a card's face prints and the entries on its page are worked out
// here, for the pocket and the card's sheet alike.
struct WalletCard: View {
    let card: BankCard
    /// Rendered width, so the corner radius can stay in proportion.
    ///
    /// A real card is 53.98 mm across with a 3.18 mm corner — 5.9% of the short
    /// side. A fixed radius stops reading as a card at thumbnail size and
    /// becomes a blob, so it scales with the card.
    var width: CGFloat = 96

    /// Real card proportions, standing up.
    static let aspect: CGFloat = 53.98 / 85.6
    /// 3.18 mm corner on a 53.98 mm width — the ISO/IEC 7810 ID-1 radius.
    static let cornerRatio: CGFloat = 3.18 / 53.98

    private var radius: CGFloat { max(width * Self.cornerRatio, 3) }
    /// Below this the card is an icon: a name would only truncate.
    private var isThumbnail: Bool { width < 60 }

    private var gradient: LinearGradient {
        LinearGradient(colors: [Color(hex: card.gradientStart), Color(hex: card.gradientEnd)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var network: CardNetwork { CardNetwork.detect(from: card.cardNumber) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            gradient
            if !isThumbnail {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Spacer(minLength: 0)
                        if !card.isDigitalWallet && network != .unknown {
                            CardNetworkLogo(network: network)
                                .scaleEffect(0.55, anchor: .topTrailing)
                        }
                    }
                    Spacer(minLength: 0)
                    Text(Self.title(for: card))
                        .font(.system(.caption2, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2).minimumScaleFactor(0.75)
                        .multilineTextAlignment(.leading)
                }
                .padding(10)
            }
        }
        .aspectRatio(Self.aspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 3, y: 2)
    }

    // MARK: Words on the face

    /// The bank, when DiPo knows it: the holder's name is the same person on
    /// every card and told none of them apart.
    static func title(for card: BankCard) -> String {
        if card.isDigitalWallet {
            return card.walletProvider.isEmpty ? loc("wallet.untitled") : card.walletProvider
        }
        if let bank = BankIssuer.find(card.issuerID)?.name { return bank }
        return card.holderName.isEmpty ? loc("wallet.untitled") : card.holderName
    }

    /// The card's own name and its last four digits, or a wallet's phone
    /// number with the middle hidden.
    static func subtitle(for card: BankCard) -> String {
        if card.isDigitalWallet {
            let digits = card.phoneNumber.filter(\.isNumber)
            guard digits.count >= 8 else { return "" }
            let local = digits.hasPrefix("62") ? "0" + digits.dropFirst(2) : digits
            return "\(local.prefix(4)) ••• \(local.suffix(4))"
        }
        let last4 = String(card.cardNumber.filter(\.isNumber).suffix(4))
        let tail = last4.count == 4 ? "•• " + last4 : ""
        // Without a known bank the holder name is already the title.
        guard BankIssuer.find(card.issuerID) != nil, !card.holderName.isEmpty else { return tail }
        return tail.isEmpty ? card.holderName : "\(card.holderName) \(tail)"
    }

    /// "Today", "Yesterday", or a short weekday and date ("Sen, 19 Okt"); the
    /// year only when it isn't this one.
    @MainActor
    static func dayLabel(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return loc("common.today") }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) {
            return loc("common.yesterday")
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return DateFormatterCache.template(sameYear ? "EEEdMMM" : "dMMMy").string(from: date)
    }

    /// The amount as a passbook prints it: a sign and the figure. The currency
    /// is the card's and already stands beside the balance, so it is left off,
    /// unless this entry was in another one.
    @MainActor
    static func amountText(_ tx: TxRecord, cardCurrency: String) -> String {
        let sign = tx.amount >= 0 ? "+" : "\u{2212}"
        let full = CurrencyManager.shared.formatted(Swift.abs(tx.amount), currency: tx.currency)
        guard tx.currency.uppercased() == cardCurrency.uppercased() else { return sign + full }
        // The same lookup `formatted` makes, so the prefix matches.
        let symbol = CurrencyManager.symbol(for: tx.currency)
        let figure = full.hasPrefix(symbol) ? String(full.dropFirst(symbol.count)) : full
        return sign + figure.trimmingCharacters(in: .whitespaces)
    }

    /// The newest `limit` entries, newest first, in one pass: a card can hold
    /// years of entries, and sorting them all to show five is waste.
    static func latest(_ txs: [TxRecord], limit: Int) -> [TxRecord] {
        guard limit > 0 else { return [] }
        var top: [TxRecord] = []
        for tx in txs {
            if top.count < limit {
                top.append(tx)
                top.sort { $0.date > $1.date }
            } else if let last = top.last, tx.date > last.date {
                top[top.count - 1] = tx
                top.sort { $0.date > $1.date }
            }
        }
        return top
    }
}
