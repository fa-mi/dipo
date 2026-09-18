import SwiftUI
import SwiftData

// MARK: - Card picker
//
// One way to choose an account, everywhere an account is chosen.
//
// There were four. A row of 80×48 mini card faces in the salary and recurring
// forms; a taller mini-card with a masked number and a currency tag when
// recording a transaction; bare name capsules on the savings deposit sheet; and
// slim spine rows in Transfer. Same decision, four visual languages, and the
// three card-shaped ones all failed the same way: a card face rendered at row
// height is a coloured blob. Every field truncates at once, and the holder name
// — identical on every card a person owns — takes the most space while telling
// you the least.
//
// So the shared language is: the card's gradient as a SPINE, the thing that
// actually distinguishes this account, and the digits underneath. Two shapes,
// because two contexts genuinely differ — a chip where a form has one line to
// spare, a row where a sheet has the height — but the same parts in the same
// order, so recognising one teaches you the other.

// MARK: Labels

enum CardLabel {
    /// What tells this card apart from the others beside it.
    ///
    /// Never the holder name alone: it is the same person on every card, so a
    /// picker headed by it three times over identifies nothing.
    static func title(_ card: BankCard) -> String {
        if card.isDigitalWallet, !card.walletProvider.isEmpty { return card.walletProvider }
        return card.holderName.isEmpty ? loc("wallet.untitled") : card.holderName
    }

    /// The digits — the one thing guaranteed unique between two cards a person
    /// named the same way. Empty for a wallet whose name already says it all;
    /// inventing a line to fill the space is how the old chips got crowded.
    static func subtitle(_ card: BankCard) -> String {
        if card.isDigitalWallet {
            return card.holderName.isEmpty || card.holderName == card.walletProvider
                ? "" : card.holderName
        }
        let last4 = String(card.cardNumber.suffix(4))
        return last4.isEmpty ? CardNetwork.detect(from: card.cardNumber).name : "·· " + last4
    }
}

// MARK: Chip

/// The compact shape, for forms. One line tall.
struct CardChip: View {
    let card: BankCard
    let selected: Bool
    /// The currency in play. When the card matches it, the tag is omitted — a
    /// label printed on every option distinguishes none of them.
    var currencyContext: String? = nil

    private var cardCurrency: String {
        card.currency.isEmpty ? CurrencyManager.shared.preferredCurrency : card.currency
    }
    private var showsCurrency: Bool {
        guard let ctx = currencyContext else { return false }
        return cardCurrency != ctx
    }

    var body: some View {
        HStack(spacing: 9) {
            LinearGradient(colors: [Color(hex: card.gradientStart), Color(hex: card.gradientEnd)],
                           startPoint: .top, endPoint: .bottom)
                .frame(width: 4, height: 28)
                .clipShape(Capsule())

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(CardLabel.title(card))
                        .font(.system(.footnote, weight: .semibold))
                        .lineLimit(1)
                    if MainCard.isMain(card) {
                        Text(loc("main.badge"))
                            .font(.system(.caption2, weight: .bold))
                            .foregroundStyle(selected ? AppTheme.bg.opacity(0.8) : AppTheme.accent)
                            .lineLimit(1).fixedSize()
                    }
                }
                HStack(spacing: 5) {
                    let sub = CardLabel.subtitle(card)
                    if !sub.isEmpty {
                        Text(sub).font(.system(.caption2))
                    }
                    if showsCurrency {
                        Text(cardCurrency)
                            .font(.system(.caption2, weight: .bold))
                            .foregroundStyle(selected ? AppTheme.onVividFill.opacity(0.75) : AppTheme.accent)
                    }
                    if card.isCreditCard {
                        Text(loc("cc.badge"))
                            .font(.system(.caption2, weight: .bold))
                            .foregroundStyle(selected ? AppTheme.onVividFill.opacity(0.75) : AppTheme.purple)
                    }
                }
                .foregroundStyle(selected ? AppTheme.onVividFill.opacity(0.7) : AppTheme.textSecondary)
            }
        }
        .foregroundStyle(selected ? AppTheme.onVividFill : AppTheme.textPrimary)
        .padding(.horizontal, 13).padding(.vertical, 9)
        .background(selected ? AppTheme.accentFill : AppTheme.cardDark,
                    in: RoundedRectangle(cornerRadius: AppRadius.md))
        .overlay {
            RoundedRectangle(cornerRadius: AppRadius.md)
                .stroke(selected ? .clear : AppTheme.cardMid, lineWidth: 1)
        }
    }
}

/// The horizontal scroller of chips — the drop-in for every form.
///
/// Selection is expressed as a predicate and a callback rather than a binding,
/// because the call sites genuinely differ: one tracks an index, one a `UUID?`,
/// one a `String?`. Forcing them onto one binding shape would mean rewriting
/// their state handling to adopt a picker, which is how call sites end up
/// keeping their own copy instead.
struct CardChipPicker: View {
    let cards: [BankCard]
    let isSelected: (BankCard) -> Bool
    let onSelect: (BankCard) -> Void
    var currencyContext: String? = nil

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(cards) { card in
                    Button {
                        HapticManager.shared.tap()
                        onSelect(card)
                    } label: {
                        CardChip(card: card, selected: isSelected(card),
                                 currencyContext: currencyContext)
                    }
                    .buttonStyle(ScaleButtonStyle())
                }
            }
            .padding(.horizontal, 22)
        }
    }
}

// MARK: Row

/// The full-width shape, for sheets that have the height — Transfer, the main
/// card picker, the setup gate. Same parts as the chip, plus the balance, which
/// only matters where you are moving money and there is room to show it.
struct CardListRow: View {
    let card: BankCard
    let selected: Bool
    /// Radio circle for a choice that is being made; checkmark-only for a list
    /// that merely marks the current one.
    var showsRadio: Bool = true

    var body: some View {
        HStack(spacing: 12) {
            LinearGradient(colors: [Color(hex: card.gradientStart), Color(hex: card.gradientEnd)],
                           startPoint: .top, endPoint: .bottom)
                .frame(width: 5, height: 38)
                .clipShape(Capsule())

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(CardLabel.title(card))
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(1)
                    if MainCard.isMain(card) {
                        Text(loc("main.badge"))
                            .font(.system(.caption2, weight: .bold))
                            .foregroundStyle(AppTheme.accent)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(AppTheme.accent.opacity(0.15), in: Capsule())
                            .lineLimit(1).fixedSize()
                    }
                }
                HStack(spacing: 6) {
                    let sub = CardLabel.subtitle(card)
                    if !sub.isEmpty {
                        Text(sub)
                        Text("·")
                    }
                    Text(card.isCreditCard ? card.formattedOwed : card.formattedBalance)
                        .fontWeight(.medium)
                }
                .font(.system(.caption2))
                .foregroundStyle(AppTheme.textSecondary)
                .lineLimit(1)
            }
            Spacer(minLength: 6)

            if showsRadio {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(.title3))
                    .foregroundStyle(selected ? AppTheme.accent : AppTheme.cardMid)
            } else if selected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(.title3)).foregroundStyle(AppTheme.accent)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(selected ? AppTheme.accent.opacity(0.10) : AppTheme.cardDark,
                    in: RoundedRectangle(cornerRadius: AppRadius.md))
        .overlay {
            RoundedRectangle(cornerRadius: AppRadius.md)
                .stroke(selected ? AppTheme.accent.opacity(0.55) : .clear, lineWidth: 1.2)
        }
    }
}
