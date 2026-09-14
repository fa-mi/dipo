import SwiftUI

// MARK: - Wallet Carousel
//
// Cards stand UP rather than lying down. A physical card is 53.98 × 85.6 mm and
// you hold it portrait; the landscape rectangle every finance app draws is a
// convention borrowed from card art, not from how anyone handles one. Standing
// them up also buys the thing a stacked list never had — several cards visible
// at once, swipeable, with the neighbours peeking in to say there are more.
//
// The glass is real material, not a painted gradient: `.ultraThinMaterial` over
// the card's own colour, so the blur picks up what is behind it and the surface
// shifts as the carousel moves. A static translucent fill looks like glass in a
// screenshot and like plastic in motion.
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
    /// Strips everything but the identity — brand mark and holder name.
    ///
    /// The full face carries a balance, a grouped PAN, a name, an expiry and a
    /// network badge. At the ~100pt used in the transfer picker there is not
    /// room for any of it: every field truncated at once ("Rp 7.529….",
    /// "SeaBan k", "E-WAL LET"). A card that small is an ICON — it only has to
    /// say which card this is, and the figures belong in the label beneath it.
    var compact: Bool = false

    @Environment(\.colorScheme) private var colorScheme

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

    private var balanceText: String {
        card.isCreditCard ? card.formattedOwed : card.formattedBalance
    }
    private var balanceLabel: String {
        loc(card.isCreditCard ? "cc.owed" : "wallet.balance")
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            gradient

            // Two different objects, two different surfaces.
            //
            // A bank card is engraved: concentric arcs, a chip, a grouped PAN.
            // An e-wallet is an APP — no chip, no embossing, no expiry; it has a
            // phone number and a brand. Dressing one as the other is why a
            // LinkAja balance read like a Mastercard.
            GeometryReader { g in
                let w = g.size.width, h = g.size.height
                if card.isDigitalWallet {
                    // Soft bloom, the way an app icon catches light.
                    RadialGradient(colors: [.white.opacity(0.24), .clear],
                                   center: .init(x: 0.18, y: 0.12),
                                   startRadius: 2, endRadius: w * 1.05)
                } else {
                    ZStack {
                        ForEach(0..<14, id: \.self) { i in
                            Circle()
                                .stroke(Color.white.opacity(0.10), lineWidth: 1.2)
                                .frame(width: w * (0.5 + Double(i) * 0.22))
                                .position(x: w * 0.92, y: h * 0.22)
                        }
                    }
                    .clipped()
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    // A wallet has no chip. It has an app.
                    if card.isDigitalWallet { providerTile } else { chip }
                    Spacer()
                    Image(systemName: card.isDigitalWallet ? "qrcode" : "wave.3.right")
                        .font(.system(.subheadline, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                }

                Spacer(minLength: 0)

                if compact && isThumbnail {
                    EmptyView()
                } else if compact {
                    Text(card.holderName.isEmpty
                         ? (card.walletProvider.isEmpty ? loc("wallet.untitled") : card.walletProvider)
                         : card.holderName)
                        .font(.system(.caption2, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2).minimumScaleFactor(0.75)
                        .multilineTextAlignment(.leading)
                } else {
                VStack(alignment: .leading, spacing: 3) {
                    Text(balanceLabel.uppercased())
                        .font(.system(.caption2, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.65))
                        .tracking(0.8)
                    Text(balanceText)
                        .font(.system(.title2, weight: .bold))
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.55)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: 6) {
                    // Monospaced grouping reads as an embossed PAN. A phone
                    // number is not embossed and shouldn't pretend to be.
                    Text(card.isHidden ? maskedIdentifier : displayNumber)
                        .font(.system(size: 12,
                                      weight: card.isDigitalWallet ? .semibold : .medium,
                                      design: card.isDigitalWallet ? .rounded : .monospaced))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1).minimumScaleFactor(0.7)
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(card.holderName.isEmpty ? loc("wallet.untitled") : card.holderName)
                                .font(.system(.caption, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1).minimumScaleFactor(0.7)
                            if card.isDigitalWallet && !card.walletProvider.isEmpty {
                                Text(card.walletProvider)
                                    .font(.system(.caption2)).foregroundStyle(.white.opacity(0.7))
                            } else if !card.expireDate.isEmpty {
                                Text(card.expireDate)
                                    .font(.system(.caption2)).foregroundStyle(.white.opacity(0.7))
                            }
                        }
                        Spacer(minLength: 6)
                        networkMark
                    }
                }
                }
            }
            .padding(isThumbnail ? 6 : (compact ? 10 : 16))

            // Glass sheen — a diagonal highlight that only reads as glass when
            // it sits ON the material, not under it.
            LinearGradient(colors: [.white.opacity(0.28), .clear, .white.opacity(0.06)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .blendMode(.softLight)
                .allowsHitTesting(false)
        }
        .aspectRatio(Self.aspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            // A hairline that catches the light, like the Home card's edge, so
            // the two surfaces read as one family.
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.08), .white.opacity(0.2)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 0.8)
        )
        // Depth as a glow in the card's OWN colours — the neon lift the Home
        // card has — instead of a flat black shadow. The small thumbnail keeps
        // a plain contact shadow so its glow can't bleed past its neighbours.
        .background {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(compact ? AnyShapeStyle(Color.black) : AnyShapeStyle(gradient))
                .scaleEffect(compact ? 1 : 0.94)
                .offset(y: (compact ? 3 : 12) * prominence)
                .blur(radius: (compact ? 6 : 20) * prominence)
                .opacity((compact ? 0.18 : (colorScheme == .dark ? 0.6 : 0.45)) * prominence)
        }
    }

    private var displayNumber: String {
        if card.isDigitalWallet && !card.phoneNumber.isEmpty { return card.phoneNumber }
        let digits = card.cardNumber.filter(\.isNumber)
        guard digits.count >= 4 else { return card.cardNumber }
        return stride(from: 0, to: digits.count, by: 4)
            .map { String(digits.dropFirst($0).prefix(4)) }
            .joined(separator: " ")
    }

    private var maskedIdentifier: String {
        card.isDigitalWallet ? "+•• ••••••••" : "•••• •••• •••• ••••"
    }

    /// The wallet's brand mark, shaped like an app icon rather than a chip.
    private var providerTile: some View {
        RoundedRectangle(cornerRadius: AppRadius.xs, style: .continuous)
            .fill(.white.opacity(0.22))
            .frame(width: 30, height: 30)
            .overlay(
                Text(String((card.walletProvider.isEmpty ? "W" : card.walletProvider).prefix(1)).uppercased())
                    .font(.system(.subheadline, design: .rounded, weight: .heavy))
                    .foregroundStyle(.white)
            )
            .overlay(RoundedRectangle(cornerRadius: AppRadius.xs).stroke(.white.opacity(0.3), lineWidth: 0.7))
    }

    private var chip: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(LinearGradient(colors: [Color(white: 0.86), Color(white: 0.62)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 32, height: 24)
            .overlay(
                VStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { _ in
                        Rectangle().fill(.black.opacity(0.18)).frame(height: 0.8)
                    }
                }
                .padding(.horizontal, 5)
            )
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(0.35), lineWidth: 0.6))
    }

    @ViewBuilder
    private var networkMark: some View {
        if card.isDigitalWallet {
            Text(loc("wallet.ewallet").uppercased())
                .font(.system(.caption2, weight: .bold))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(.white.opacity(0.18), in: Capsule())
        } else if card.isCreditCard {
            Text(loc("cc.badge"))
                .font(.system(.caption2, weight: .bold))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(.white.opacity(0.18), in: Capsule())
        } else {
            CardNetworkLogo(network: CardNetwork.detect(from: card.cardNumber))
                .frame(height: 18)
        }
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
    let txCount: Int
    var onEdit: () -> Void
    var onDelete: () -> Void
    /// Observed so the badge and the star swap the instant the choice changes.
    @State private var sb = SmartBudgetManager.shared

    private var isMain: Bool {
        let _ = sb.budgetCardID
        return MainCard.isMain(card)
    }

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(Color(hex: card.gradientStart)).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(subtitle)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary).lineLimit(1)
                    // Which account the whole app is reasoning about, stated on
                    // the account itself. Anywhere else and the user has to
                    // remember a setting to read their own numbers.
                    if isMain {
                        Text(loc("main.badge"))
                            .font(.system(.caption2, weight: .bold))
                            .foregroundStyle(AppTheme.accent)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(AppTheme.accent.opacity(0.15), in: Capsule())
                    }
                }
                Text(String(format: loc(txCount == 1 ? "cards.tx_count" : "cards.tx_counts"), txCount))
                    .font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
            }
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

    }

    private var subtitle: String {
        if card.isDigitalWallet && !card.walletProvider.isEmpty { return card.walletProvider }
        if card.isCreditCard { return loc("cc.title") }
        return CardNetwork.detect(from: card.cardNumber).name
    }
}
