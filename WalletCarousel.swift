import SwiftUI

// MARK: - Wallet Carousel
//
// Cards stand UP rather than lying down. A physical card is 53.98 × 85.6 mm and
// you hold it portrait; the landscape rectangle every finance app draws is a
// convention borrowed from card art, not from how anyone handles one. Standing
// them up also buys the thing a stacked list never had — several cards visible
// at once, swipeable, with the neighbours peeking in to say there are more.
//
// The face is a passbook, not a piece of plastic. DiPo never holds the card, so
// the chip, the contactless waves, the engraved arcs and the glass sheen it
// used to wear said nothing: five layers of decoration over a face that left
// out the one thing that tells two cards apart, the bank. The cover now says
// which bank, which card and what is in it; the page below it, like the inside
// of a buku tabungan, shows the last two entries on that card.
struct WalletCard: View {
    let card: BankCard
    /// 0 = fully scrolled away, 1 = centred. Drives the depth cues.
    var prominence: Double = 1
    /// Rendered width, so the corner radius can stay in proportion.
    ///
    /// A real card is 53.98 mm across with a 3.18 mm corner — 5.9% of the short
    /// side. A fixed 22pt radius was ~11% at carousel size and 50% at the 44pt
    /// thumbnail, where it stopped reading as a card at all and became a blob.
    /// Radius has to scale with the card or the shape stops being a card's.
    var width: CGFloat = 208
    /// Strips everything but the identity — the bank and the principal.
    ///
    /// At the ~100pt used in the transfer picker there is not room for a
    /// balance or a page of entries: every field truncated at once. A card that
    /// small is an ICON — it only has to say which card this is, and the
    /// figures belong in the label beneath it.
    var compact: Bool = false

    @Environment(\.colorScheme) private var colorScheme
    /// Observed so the main-card mark moves the moment the choice changes.
    @State private var sb = SmartBudgetManager.shared

    /// Real card proportions, standing up.
    static let aspect: CGFloat = 53.98 / 85.6
    /// 3.18 mm corner on a 53.98 mm width — the ISO/IEC 7810 ID-1 radius.
    static let cornerRatio: CGFloat = 3.18 / 53.98
    /// The cover's share of the height; the page takes the rest.
    static let coverShare: CGFloat = 0.63
    /// Entries on the page. Two fit at every text size up to the largest
    /// non-accessibility one; a third pushed the balance off the cover.
    static let pageRows = 2

    private var radius: CGFloat { max(width * Self.cornerRatio, 3) }
    /// Below this the card is an icon: a name would only truncate.
    private var isThumbnail: Bool { width < 60 }

    private var gradient: LinearGradient {
        LinearGradient(colors: [Color(hex: card.gradientStart), Color(hex: card.gradientEnd)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var network: CardNetwork { CardNetwork.detect(from: card.cardNumber) }

    private var isMain: Bool {
        let _ = sb.budgetCardID
        return !card.isCreditCard && MainCard.isMain(card)
    }

    var body: some View {
        Group {
            if compact { icon } else { passbook }
        }
        .aspectRatio(Self.aspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        // A hairline so the page, which is the colour of any other card in the
        // app, still has an edge against the screen behind it.
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.10 : 0.0), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity((compact ? 0.18 : (colorScheme == .dark ? 0.35 : 0.14)) * prominence),
                radius: compact ? 3 : 10, y: (compact ? 2 : 6) * prominence)
    }

    // MARK: Full face

    private var passbook: some View {
        GeometryReader { g in
            VStack(spacing: 0) {
                cover
                    .frame(height: g.size.height * Self.coverShare)
                page
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(AppTheme.cardDark)
            }
        }
    }

    private var cover: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(Self.title(for: card))
                        .font(.system(.title3, weight: .bold))
                        .lineLimit(1).minimumScaleFactor(0.7)
                    let sub = Self.subtitle(for: card)
                    if !sub.isEmpty {
                        Text(sub)
                            .font(.system(.footnote))
                            .foregroundStyle(.white.opacity(0.78))
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                }
                Spacer(minLength: 0)
                // The principal, where a real card prints it. A wallet has none.
                if !card.isDigitalWallet && network != .unknown {
                    CardNetworkLogo(network: network)
                        .scaleEffect(0.8, anchor: .topTrailing)
                        .accessibilityLabel(network.name)
                }
            }

            Spacer(minLength: 4)

            HStack(alignment: .firstTextBaseline) {
                Text(loc(card.isCreditCard ? "cc.owed" : "wallet.balance"))
                    .font(.system(.footnote))
                    .foregroundStyle(.white.opacity(0.75))
                Spacer(minLength: 6)
                if isMain {
                    Label(loc("main.badge"), systemImage: "star.fill")
                        .font(.system(.caption, weight: .semibold))
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.white.opacity(0.2), in: Capsule())
                        .lineLimit(1).fixedSize()
                }
            }
            Text(card.isHidden ? "••••••" : (card.isCreditCard ? card.formattedOwed : card.formattedBalance))
                .font(.system(.title, weight: .bold))
                .monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.5)
                .padding(.top, 2)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(gradient)
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: 6) {
            if card.isCreditCard && card.creditLimit > 0 {
                limitBar
            } else {
                Text(loc("wallet.recent"))
                    .font(.system(.caption))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            if card.isHidden {
                Text(loc("wallet.recent_hidden"))
                    .font(.system(.footnote))
                    .foregroundStyle(AppTheme.textSecondary)
            } else {
                let rows = Self.latest(card.transactions, limit: Self.pageRows)
                if rows.isEmpty {
                    Text(loc("wallet.no_recent"))
                        .font(.system(.footnote))
                        .foregroundStyle(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(rows) { tx in entry(tx) }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    /// One printed line of the passbook, signed the way TxRow signs it.
    private func entry(_ tx: TxRecord) -> some View {
        VStack(spacing: 6) {
            Rectangle().fill(AppTheme.textSecondary.opacity(0.15)).frame(height: 0.5)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(tx.name)
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(tx.amount >= 0
                     ? "+\(CurrencyManager.shared.formatted(tx.amount, currency: tx.currency))"
                     : CurrencyManager.shared.formatted(tx.amount, currency: tx.currency))
                    .monospacedDigit()
                    .foregroundStyle(tx.amount >= 0 ? AppTheme.green : AppTheme.textPrimary)
                    .lineLimit(1).fixedSize()
            }
            .font(.system(.footnote))
        }
    }

    /// How much of the limit is used — the number a credit card's owed figure
    /// means nothing without.
    private var limitBar: some View {
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(AppTheme.textSecondary.opacity(0.2))
                    // The instalment simulator's rule: past 70% the bar turns red.
                    Capsule().fill(card.creditUtilization > 0.7 ? AppTheme.red : AppTheme.accent)
                        .frame(width: g.size.width * card.creditUtilization)
                }
            }
            .frame(height: 6)
            Text(String(format: loc("wallet.limit_share"),
                        Int((card.creditUtilization * 100).rounded()),
                        CurrencyManager.shared.formatted(card.creditLimit, currency: card.resolvedCurrency)))
                .font(.system(.caption))
                .foregroundStyle(AppTheme.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
    }

    // MARK: Icon (transfer picker)

    private var icon: some View {
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

    /// The newest `limit` entries, newest first, in one pass: this runs for
    /// every card in the carousel and a card can hold years of entries.
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

// MARK: - Carousel

struct WalletCarousel: View {
    let cards: [BankCard]
    @Binding var selectedID: UUID?

    /// Portrait cards need most of the width to stay legible, but not all of
    /// it — the sliver of the next card is what tells you to swipe.
    private let cardWidth: CGFloat = 208

    /// Measured once from the layout this carousel is given, so the side
    /// padding that centres the first and last card is based on the space that
    /// actually exists rather than on the device's screen.
    @State private var containerWidth: CGFloat = 0

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 16) {
                ForEach(cards) { card in
                    WalletCard(card: card, width: cardWidth)
                        .frame(width: cardWidth)
                        .scrollTransition(axis: .horizontal) { content, phase in
                            // Neighbours shrink and fade, so the centred card
                            // reads as the one in hand.
                            content
                                .scaleEffect(phase.isIdentity ? 1 : 0.90)
                                .opacity(phase.isIdentity ? 1 : 0.55)
                        }
                        .id(card.id)
                }
            }
            .scrollTargetLayout()
            // The container's own width, not the screen's. `UIScreen.main` is
            // deprecated in iOS 26 and was always the wrong question anyway —
            // it gives the display, while the padding needs the space this
            // carousel was actually handed.
            .padding(.horizontal, max((containerWidth - cardWidth) / 2, 0))
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $selectedID)
        .frame(height: cardWidth / WalletCard.aspect + 40)
        .background {
            GeometryReader { g in
                Color.clear
                    .onAppear { containerWidth = g.size.width }
                    .onChange(of: g.size.width) { _, w in containerWidth = w }
            }
        }
    }
}

// MARK: - Page dots

struct WalletPageDots: View {
    let cards: [BankCard]
    let selectedID: UUID?

    var body: some View {
        HStack(spacing: 6) {
            ForEach(cards) { card in
                Capsule()
                    .fill(card.id == selectedID ? AppTheme.accent : AppTheme.textSecondary.opacity(0.28))
                    .frame(width: card.id == selectedID ? 18 : 6, height: 6)
                    .animation(.spring(response: 0.3, dampingFraction: 0.75), value: selectedID)
            }
        }
    }
}


// MARK: - Actions for the centred card
//
// Deliberately carries NO card art and NO balance. Both already sit in the
// carousel directly above; repeating them was the duplication this replaces.
struct WalletCardActions: View {
    @Bindable var card: BankCard
    var onEdit: () -> Void
    var onDelete: () -> Void
    /// Observed so the badge and the star swap the instant the choice changes.
    @State private var sb = SmartBudgetManager.shared
    @State private var showMatchBalance = false

    private var isMain: Bool {
        let _ = sb.budgetCardID
        return MainCard.isMain(card)
    }

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(Color(hex: card.gradientStart)).frame(width: 9, height: 9)
            // Name over badge, not beside it. With four round buttons on the
            // right, a name and a badge on one line left the name a single
            // clipped letter ("M" for Mastercard), and the transaction count
            // under it wrapped onto three lines. The count is gone: the
            // carousel's card already says what matters, and a number of rows
            // says nothing about the money.
            VStack(alignment: .leading, spacing: 4) {
                Text(subtitle)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                // Which account the whole app is reasoning about, stated on
                // the account itself. Anywhere else and the user has to
                // remember a setting to read their own numbers.
                if isMain {
                    Text(loc("main.badge"))
                        .font(.system(.caption2, weight: .bold))
                        .foregroundStyle(AppTheme.accent)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(AppTheme.accent.opacity(0.15), in: Capsule())
                        .lineLimit(1).fixedSize()
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            // One gesture, no sheet.
            //
            // Tapping the filled star used to open a picker listing every card —
            // which is the same choice again, one level deeper, in a screen that
            // already has all the cards laid out in a carousel. The wallet IS
            // the picker: swipe to the card you want and star it.
            //
            // So on the current anchor the star is a STATUS, not a button.
            // Nothing to tap, because there is nothing left to decide here.
            if !card.isCreditCard {
                if isMain {
                    Image(systemName: "star.fill")
                        .font(.system(.subheadline))
                        .foregroundStyle(AppTheme.bg)
                        .frame(width: 36, height: 36)
                        .background(AppTheme.accentFill, in: Circle())
                        .accessibilityLabel(loc("main.is_main"))
                } else {
                    Button {
                        HapticManager.shared.success()
                        withAnimation(AppMotion.move) { MainCard.set(card) }
                    } label: {
                        Image(systemName: "star")
                            .font(.system(.subheadline))
                            .foregroundStyle(AppTheme.accent)
                            .frame(width: 36, height: 36)
                            .background(AppTheme.accent.opacity(0.12), in: Circle())
                    }
                    .buttonStyle(ScaleButtonStyle())
                    .accessibilityLabel(loc("main.make_main"))
                }
            }
            // Match DiPo's balance to the bank's — for the drift a hand-kept
            // ledger gathers. A credit card's figure is what is owed, not a
            // balance to read off a bank app, so it isn't offered there.
            if !card.isCreditCard {
                Button { HapticManager.shared.tap(); showMatchBalance = true } label: {
                    Image(systemName: "equal.circle")
                        .font(.system(.subheadline)).foregroundStyle(AppTheme.textSecondary)
                        .frame(width: 36, height: 36)
                        .background(AppTheme.cardMid, in: Circle())
                }
                .accessibilityLabel(loc("match.title"))
                .buttonStyle(ScaleButtonStyle())
            }
            Button { HapticManager.shared.tap(); onEdit() } label: {
                Image(systemName: "pencil")
                    .font(.system(.subheadline)).foregroundStyle(AppTheme.textSecondary)
                    .frame(width: 36, height: 36)
                    .background(AppTheme.cardMid, in: Circle())
            }
.accessibilityLabel(loc("common.edit"))
            .buttonStyle(ScaleButtonStyle())
            Button { HapticManager.shared.warning(); onDelete() } label: {
                Image(systemName: "trash")
                    .font(.system(.subheadline)).foregroundStyle(AppTheme.red.opacity(0.85))
                    .frame(width: 36, height: 36)
                    .background(AppTheme.red.opacity(0.12), in: Circle())
            }
.accessibilityLabel(loc("common.delete"))
            .buttonStyle(ScaleButtonStyle())
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
        .sheet(isPresented: $showMatchBalance) {
            MatchBalanceSheet(card: card)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
                .preferredColorScheme(appColorScheme())
        }
    }

    /// The same name the card's face carries, so the row and the card agree.
    private var subtitle: String { WalletCard.title(for: card) }
}
