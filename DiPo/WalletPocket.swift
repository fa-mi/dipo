import SwiftUI

// MARK: - The wallet pocket
//
// Cards tucked into a pocket, the way a wallet holds them: each one's top edge
// shows above the next, with the bank on the left and what is in it on the
// right. A credit card shows its bill there instead. What they add up to is
// printed on the pocket itself, so the total has a place of its own rather than
// riding on one card's face.
//
// Tapping a card pulls it out: its whole face, what can be done with it, and
// its latest entries, in a sheet (`WalletCardSheet`).
//
// There are two pockets, swiped between: one for conventional banks, one for
// digital banks and e-wallets (`WalletPockets`). The pocket is dark leather in
// both themes, the cards sit inside it with its lining showing at their sides,
// as in a card holder.

// MARK: - Two pockets

/// Which pocket a card sits in: digital banks and e-wallets in one, every
/// other bank in the other. Read from what the card already knows — its bank,
/// or that it is an e-wallet — so nothing new is stored, and a card whose bank
/// DiPo doesn't know goes with the conventional banks, where most cards are.
enum WalletPocketKind: String, CaseIterable, Identifiable {
    case conventional, digital

    var id: String { rawValue }

    /// Banks that are digital banks, by `BankIssuer` id: an app is the bank,
    /// with no branches. Jenius is BTPN's digital bank.
    static let digitalBanks: Set<String> = ["jago", "seabank", "blu", "allo", "linebank", "neo", "jenius"]

    static func of(_ card: BankCard) -> WalletPocketKind {
        if card.isDigitalWallet { return .digital }
        return digitalBanks.contains(card.issuerID) ? .digital : .conventional
    }

    var title: String {
        loc(self == .conventional ? "wallet.pocket_conventional" : "wallet.pocket_digital")
    }

    /// The pockets that hold a card, conventional first, in the wallet's order.
    static func groups(_ cards: [BankCard]) -> [WalletPocketGroup] {
        allCases.compactMap { kind in
            let held = cards.filter { of($0) == kind }
            return held.isEmpty ? nil : WalletPocketGroup(kind: kind, cards: held)
        }
    }
}

struct WalletPocketGroup: Identifiable {
    let kind: WalletPocketKind
    let cards: [BankCard]
    var id: WalletPocketKind { kind }
}

/// The pockets side by side, swiped between. The names above say which one is
/// in front, and a tap on the other brings it forward the way a swipe does. As
/// a pocket slides away it shrinks a little toward its top and its cards sink
/// into it; the arriving pocket's cards rise.
///
/// Each pocket sits right under the names, and the pager is as tall as the
/// pocket in front, so what comes after it moves with the cards. The pockets
/// were bottom-aligned at first, to keep both totals level, and a pocket of
/// three cards then floated under two cards' worth of empty space whenever
/// the other held five.
struct WalletPockets: View {
    let cards: [BankCard]
    var onOpen: (BankCard) -> Void

    /// The pocket in front. Nil until the first swipe or tap: the first one.
    @State private var shown: WalletPocketKind?
    /// Each pocket's frame against the pager, as it scrolls: where it is
    /// across, and how tall it is.
    @State private var frames: [WalletPocketKind: CGRect] = [:]
    @Namespace private var underline

    /// The pager's height: each pocket's own, counted by how much of it is in
    /// view. Halfway through a swipe it is halfway between the two, so what
    /// sits below follows the finger instead of jumping when the swipe lands.
    /// Nil until the pockets have been measured, and the pager then takes its
    /// natural height for that first moment.
    static func height(of frames: [WalletPocketKind: CGRect], kinds: [WalletPocketKind]) -> CGFloat? {
        var sum: CGFloat = 0
        var weight: CGFloat = 0
        for kind in kinds {
            guard let f = frames[kind], f.width > 0 else { continue }
            let inView = max(0, 1 - abs(f.minX) / f.width)
            sum += f.height * inView
            weight += inView
        }
        return weight > 0 ? sum / weight : nil
    }

    private static let move = Animation.spring(response: 0.42, dampingFraction: 0.86)

    var body: some View {
        let groups = WalletPocketKind.groups(cards)
        // A pocket emptied by a deletion falls back to the first.
        let current = groups.first { $0.kind == shown }?.kind ?? groups.first?.kind
        VStack(alignment: .leading, spacing: 16) {
            if groups.count > 1 {
                tabs(groups.map(\.kind), current: current)
                    .padding(.horizontal, 22)
            }
            ScrollView(.horizontal) {
                // Top-aligned, right under the names.
                HStack(alignment: .top, spacing: 0) {
                    ForEach(groups) { group in
                        WalletPocket(cards: group.cards, onOpen: onOpen)
                            .padding(.horizontal, 22)
                            .containerRelativeFrame(.horizontal)
                            .scrollTransition(.interactive, axis: .horizontal) { content, phase in
                                content.scaleEffect(CGFloat(1 - 0.05 * abs(phase.value)), anchor: .top)
                            }
                            // Outside the transition, so its scaling isn't measured.
                            .onGeometryChange(for: CGRect.self) { proxy in
                                proxy.frame(in: .named("walletPockets"))
                            } action: { frames[group.kind] = $0 }
                    }
                }
                .scrollTargetLayout()
                // The height is set here, on the content, not on the scroll
                // view: content taller than a scroll view would be centred in
                // it, cut at the top and the bottom. Here the taller pocket
                // runs past the foot and is clipped there, while it slides in.
                .frame(height: Self.height(of: frames, kinds: groups.map(\.kind)), alignment: .top)
                // Room inside the scroll view, which clips, for the top card's
                // shadow and the pocket's own on the page, taken back outside
                // so the layout doesn't move.
                .padding(.top, Self.shadowRoom.top)
                .padding(.bottom, Self.shadowRoom.bottom)
            }
            .coordinateSpace(.named("walletPockets"))
            .scrollTargetBehavior(.paging)
            .scrollIndicators(.hidden)
            .scrollPosition(id: $shown)
            .scrollDisabled(groups.count < 2)
            .padding(.top, -Self.shadowRoom.top)
            .padding(.bottom, -Self.shadowRoom.bottom)
        }
    }

    private static let shadowRoom = (top: CGFloat(8), bottom: CGFloat(22))

    /// The pockets by name, the one in front in ink and underlined.
    private func tabs(_ kinds: [WalletPocketKind], current: WalletPocketKind?) -> some View {
        HStack(spacing: 20) {
            ForEach(kinds) { kind in
                let on = kind == current
                Button {
                    guard !on else { return }
                    HapticManager.shared.tap()
                    withAnimation(Self.move) { shown = kind }
                } label: {
                    Text(kind.title)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(on ? AppTheme.textPrimary : AppTheme.textSecondary)
                        .lineLimit(1).minimumScaleFactor(0.75)
                        .padding(.bottom, 7)
                        .overlay(alignment: .bottom) {
                            if on {
                                Capsule()
                                    .fill(AppTheme.textPrimary)
                                    .frame(height: 2)
                                    .matchedGeometryEffect(id: "underline", in: underline)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .animation(Self.move, value: current)
    }
}

// MARK: - One pocket

struct WalletPocket: View {
    let cards: [BankCard]
    var onOpen: (BankCard) -> Void

    /// How much of each card shows above the next one. Scaled with the text
    /// on it, so a larger size does not push the figures under the next card.
    @ScaledMetric(relativeTo: .headline) private var strip: CGFloat = 64
    /// How much of the front card shows above the pocket's sides.
    @ScaledMetric(relativeTo: .headline) private var front: CGFloat = 104
    @Environment(\.colorScheme) private var colorScheme
    /// How far the pocket's lip dips in the middle: a thumb notch.
    static let dip: CGFloat = 18
    /// How far the cards sit in from the pocket's sides, so its lining shows
    /// beside them.
    static let inset: CGFloat = 12
    /// The pocket's corners, lining and front alike.
    static let corner: CGFloat = 20
    /// How far the cards sink into a pocket that is sliding away.
    static let sink: CGFloat = 26

    private var stackHeight: CGFloat { CGFloat(max(cards.count - 1, 0)) * strip + front }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                ForEach(Array(cards.enumerated()), id: \.element.id) { i, card in
                    Button { onOpen(card) } label: {
                        // Its own height for the width, not the stack's: the
                        // stack is shorter than a card and would shrink it.
                        WalletPocketCard(card: card)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .buttonStyle(.plain)
                    .offset(y: CGFloat(i) * strip)
                    .zIndex(Double(i))
                }
            }
            .padding(.horizontal, Self.inset)
            .scrollTransition(.interactive, axis: .horizontal) { content, phase in
                content.offset(y: CGFloat(abs(phase.value)) * Self.sink)
            }
            // The front card runs on under the pocket; it ends at the lip's
            // lowest point, so a short pocket never shows its lower edge, and
            // a card sinking in disappears behind the front. The mask reaches
            // past the sides and the top to keep the shadows.
            .frame(height: stackHeight + Self.dip, alignment: .top)
            .mask { Rectangle().padding(.horizontal, -24).padding(.top, -24) }

            WalletPocketFace(totals: Self.totals(of: cards, preferred: CurrencyManager.shared.preferredCurrency))
                .padding(.top, -Self.dip)
        }
        // The lining, behind the cards from just under the first one's name
        // down to the front, whose corners it shares. Dark in both themes, so
        // in the light one it casts a soft shadow on the page.
        .background(alignment: .top) {
            RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                .fill(AppTheme.flowGround)
                .padding(.top, strip * 0.55)
                .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.16), radius: 12, y: 6)
        }
    }

    // MARK: What it adds up to

    struct Amount: Equatable {
        let currency: String
        let value: Double
    }

    /// The cash in each currency (debit cards and wallets) and what the credit
    /// cards owe in each, the preferred currency first. A currency is never
    /// converted into another: a total in rupiah plus a total in dollars says
    /// what is there; one figure at today's rate would be a guess.
    ///
    /// A card whose figures are hidden still counts. Hiding is about what a
    /// face shows, not about what the person has.
    static func totals(of cards: [BankCard], preferred: String) -> (cash: [Amount], bills: [Amount]) {
        var cash: [String: Double] = [:]
        var bills: [String: Double] = [:]
        for card in cards {
            if card.isCreditCard {
                let owed = card.owedBalance()
                if owed >= 0.5 { bills[card.resolvedCurrency, default: 0] += owed }
            } else {
                cash[card.resolvedCurrency, default: 0] += card.computedBalance()
            }
        }
        func ordered(_ sums: [String: Double]) -> [Amount] {
            sums.map { Amount(currency: $0.key, value: $0.value) }.sorted { a, b in
                if a.currency == b.currency { return false }
                if a.currency == preferred { return true }
                if b.currency == preferred { return false }
                return a.currency < b.currency
            }
        }
        return (ordered(cash), ordered(bills))
    }
}

// MARK: - A card in the pocket

/// A card lying sideways, as it sits in a wallet. Only its top strip shows in
/// the pocket, so that is where everything it has to say goes, and nothing
/// else: the bank, the card, and what is in it.
struct WalletPocketCard: View {
    let card: BankCard

    @Environment(\.colorScheme) private var colorScheme
    /// Observed so the main-card mark moves the moment the choice changes.
    @State private var sb = SmartBudgetManager.shared

    /// ID-1, lying down.
    static let aspect: CGFloat = 85.6 / 53.98

    var body: some View {
        ZStack(alignment: .topLeading) {
            WalletCardFace.gradient(for: card)
            WalletCardFace.header(card, isMain: WalletCardFace.isMain(card, sb), figures: true)
                .padding(.horizontal, 15).padding(.top, 13)
        }
        .aspectRatio(Self.aspect, contentMode: .fit)
        .clipShape(WalletCardFace.shape)
        // A short shadow cast upward, onto the card behind: two cards of the
        // same bank colour would otherwise read as one.
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.3 : 0.14), radius: 4, y: -1)
        .contentShape(WalletCardFace.shape)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - The pocket

/// The pocket's face: the total cash, and what the credit cards owe. The
/// pocket is dark in both themes, so its words are white.
struct WalletPocketFace: View {
    let totals: (cash: [WalletPocket.Amount], bills: [WalletPocket.Amount])

    /// A label on the pocket.
    private var quiet: Color { Color.white.opacity(0.62) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(loc("wallet.total_cash"))
                .font(.system(.footnote))
                .foregroundStyle(quiet)
            if totals.cash.isEmpty {
                figure(WalletPocket.Amount(currency: CurrencyManager.shared.preferredCurrency, value: 0), lead: true)
            }
            ForEach(Array(totals.cash.enumerated()), id: \.element.currency) { i, item in
                figure(item, lead: i == 0)
            }
            if !totals.bills.isEmpty {
                Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1).padding(.top, 12)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(loc("wallet.cc_bills"))
                        .font(.system(.footnote))
                        .foregroundStyle(quiet)
                    Spacer(minLength: 8)
                    Text(totals.bills.map { CurrencyManager.shared.formatted($0.value, currency: $0.currency) }
                        .joined(separator: " · "))
                        .font(.system(.footnote, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                .padding(.top, 10)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, WalletPocket.dip + 16)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            // The front: the lining's dark a shade lifted, its lip catching
            // the light so it reads apart from the lining where they meet,
            // and a short shadow cast up onto the cards.
            ZStack {
                WalletPocketShape(dip: WalletPocket.dip).fill(AppTheme.flowGround)
                WalletPocketShape(dip: WalletPocket.dip).fill(Color.white.opacity(0.05))
                WalletPocketLip(dip: WalletPocket.dip).stroke(Color.white.opacity(0.1), lineWidth: 1)
            }
            .compositingGroup()
            .shadow(color: .black.opacity(0.35), radius: 6, y: -3)
        }
        .accessibilityElement(children: .combine)
    }

    /// One currency's total: the first large, any other one under it smaller.
    /// White, not green: the money is the loudest thing here by its size, and
    /// green is kept for the one action. Red only when it is below zero.
    private func figure(_ item: WalletPocket.Amount, lead: Bool) -> some View {
        Text((item.value < 0 ? "-" : "")
             + CurrencyManager.shared.formatted(Swift.abs(item.value), currency: item.currency))
            .font(.system(lead ? .title : .headline, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(item.value < 0 ? AppTheme.red : .white)
            .lineLimit(1).minimumScaleFactor(0.6)
            .contentTransition(.numericText())
            .padding(.top, lead ? 2 : 4)
    }
}

/// The pocket: a lip that dips toward the middle, like a wallet's card slot,
/// over a body with rounded lower corners.
struct WalletPocketShape: Shape {
    var dip: CGFloat

    func path(in r: CGRect) -> Path {
        let radius: CGFloat = 20   // WalletPocket.corner, the lining's
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        Self.lip(&p, from: r.minX, to: r.maxX, y: r.minY, dip: dip)
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - radius))
        p.addQuadCurve(to: CGPoint(x: r.maxX - radius, y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + radius, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - radius), control: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }

    /// The lip from `x0` to `x1`, at `y` on the sides and `y + dip` mid-way.
    /// Nonisolated: it is drawn from `path(in:)`, which SwiftUI calls off the
    /// main actor.
    nonisolated static func lip(_ p: inout Path, from x0: CGFloat, to x1: CGFloat, y: CGFloat, dip: CGFloat) {
        let w = x1 - x0
        p.addCurve(to: CGPoint(x: x0 + w / 2, y: y + dip),
                   control1: CGPoint(x: x0 + w * 0.27, y: y),
                   control2: CGPoint(x: x0 + w * 0.29, y: y + dip))
        p.addCurve(to: CGPoint(x: x1, y: y),
                   control1: CGPoint(x: x0 + w * 0.71, y: y + dip),
                   control2: CGPoint(x: x0 + w * 0.73, y: y))
    }
}

/// The lip alone, drawn as a line: the light along the pocket's edge.
struct WalletPocketLip: Shape {
    var dip: CGFloat

    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY + 0.5))
        WalletPocketShape.lip(&p, from: r.minX, to: r.maxX, y: r.minY + 0.5, dip: dip)
        return p
    }
}

// MARK: - What a face shows

/// What the card in the pocket and the card in the sheet print alike, so the
/// two always agree.
enum WalletCardFace {
    /// A real card's 3.18 mm corner on its 53.98 mm short side, at the
    /// pocket's width.
    static let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)

    static func gradient(for card: BankCard) -> LinearGradient {
        LinearGradient(colors: [Color(hex: card.gradientStart), Color(hex: card.gradientEnd)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// The account the whole app reasons about. `sb` is read so a view that
    /// passes it in redraws when the choice changes.
    static func isMain(_ card: BankCard, _ sb: SmartBudgetManager) -> Bool {
        let _ = sb.budgetCardID
        return !card.isCreditCard && MainCard.isMain(card)
    }

    /// The balance, or for a credit card the bill; dots while hidden.
    static func amount(_ card: BankCard) -> String {
        card.isHidden ? "••••••" : (card.isCreditCard ? card.formattedOwed : card.formattedBalance)
    }

    static func amountLabel(_ card: BankCard) -> String {
        loc(card.isCreditCard ? "cc.owed" : "wallet.balance")
    }

    /// The bank and the card's own name on the left; with `figures`, what is
    /// in it on the right. A balance needs no label beside a bank's name; a
    /// bill does, or it reads as money the person has.
    static func header(_ card: BankCard, isMain: Bool, figures: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(WalletCard.title(for: card))
                        .font(.system(.headline, weight: .bold))
                        .lineLimit(1).minimumScaleFactor(0.7)
                    // The main account: a star, which the card's sheet names.
                    if isMain {
                        Image(systemName: "star.fill")
                            .font(.system(.caption2))
                            .accessibilityLabel(loc("main.is_main"))
                    }
                }
                let sub = WalletCard.subtitle(for: card)
                if !sub.isEmpty {
                    Text(sub)
                        .font(.system(.caption))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if figures {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(amount(card))
                        .font(.system(.headline, weight: .semibold))
                        .monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.6)
                    if card.isCreditCard {
                        Text(amountLabel(card))
                            .font(.system(.caption))
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(1)
                    }
                }
                .layoutPriority(1)
            }
        }
        .foregroundStyle(.white)
    }
}

// MARK: - A card, pulled out

/// One card out of the pocket: its whole face, what can be done with it, and
/// its latest entries.
struct WalletCardSheet: View {
    @Bindable var card: BankCard
    var onEdit: () -> Void
    var onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var sb = SmartBudgetManager.shared
    @State private var showMatchBalance = false

    /// Entries on the sheet's page.
    static let entries = 5

    private var network: CardNetwork { CardNetwork.detect(from: card.cardNumber) }
    private var isMain: Bool { WalletCardFace.isMain(card, sb) }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    face
                    actions.padding(.top, 18)
                    page.padding(.top, 22)
                }
                .padding(.horizontal, 22)
                .padding(.top, 4)
                .padding(.bottom, 32)
                .containerRelativeFrame(.horizontal)
            }
            .background(AppTheme.bg)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .doneToolbar { dismiss() }
        }
        .sheet(isPresented: $showMatchBalance) {
            MatchBalanceSheet(card: card)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
                .preferredColorScheme(appColorScheme())
        }
    }

    // MARK: The face

    private var face: some View {
        ZStack(alignment: .topLeading) {
            WalletCardFace.gradient(for: card)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 8) {
                    WalletCardFace.header(card, isMain: isMain, figures: false)
                    if !card.isDigitalWallet && network != .unknown {
                        CardNetworkLogo(network: network)
                            .scaleEffect(0.9, anchor: .topTrailing)
                            .accessibilityLabel(network.name)
                    }
                }
                Spacer(minLength: 8)
                Text(WalletCardFace.amountLabel(card))
                    .font(.system(.footnote))
                    .foregroundStyle(.white.opacity(0.78))
                Text(WalletCardFace.amount(card))
                    .font(.system(.title, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.5)
                    .padding(.top, 1)
                if card.isCreditCard && card.creditLimit > 0 && !card.isHidden { limitBar.padding(.top, 10) }
            }
            .padding(16)
        }
        .aspectRatio(WalletPocketCard.aspect, contentMode: .fit)
        .clipShape(WalletCardFace.shape)
        .accessibilityElement(children: .combine)
    }

    /// How much of the limit is used: the figure a credit card's bill means
    /// nothing without. Past 70% it turns red, the instalment simulator's rule.
    private var limitBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25))
                    Capsule().fill(card.creditUtilization > 0.7 ? AppTheme.red : .white)
                        .frame(width: g.size.width * card.creditUtilization)
                }
            }
            .frame(height: 6)
            Text(String(format: loc("wallet.limit_share"),
                        Int((card.creditUtilization * 100).rounded()),
                        CurrencyManager.shared.formatted(card.creditLimit, currency: card.resolvedCurrency)))
                .font(.system(.caption))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1).minimumScaleFactor(0.8)
        }
    }

    // MARK: What can be done with it

    private var actions: some View {
        HStack(alignment: .top, spacing: 0) {
            // The star and the match are a cash account's: a credit card's
            // figure is a bill, not a balance to read off a bank app.
            if !card.isCreditCard {
                if isMain {
                    // A status, not a button: there is nothing left to decide.
                    actionLabel("star.fill", loc("main.badge"), tint: AppTheme.accent)
                        .accessibilityLabel(loc("main.is_main"))
                } else {
                    Button {
                        HapticManager.shared.success()
                        withAnimation(AppMotion.move) { MainCard.set(card) }
                    } label: {
                        actionLabel("star", loc("wallet.act_main"))
                    }
                    .buttonStyle(ScaleButtonStyle())
                    .accessibilityLabel(loc("main.make_main"))
                }
                Button {
                    HapticManager.shared.tap()
                    showMatchBalance = true
                } label: {
                    actionLabel("equal.circle", loc("wallet.act_match"))
                }
                .buttonStyle(ScaleButtonStyle())
                .accessibilityLabel(loc("match.title"))
            }
            Button {
                HapticManager.shared.tap()
                onEdit()
            } label: {
                actionLabel("pencil", loc("common.edit"))
            }
            .buttonStyle(ScaleButtonStyle())
            Button {
                HapticManager.shared.warning()
                onDelete()
            } label: {
                actionLabel("trash", loc("common.delete"), tint: AppTheme.red, label: AppTheme.red)
            }
            .buttonStyle(ScaleButtonStyle())
        }
    }

    /// A glyph over its name, and nothing behind them: the row is the
    /// card's toolbar, not four more things to look at.
    private func actionLabel(_ icon: String, _ title: String, tint: Color = AppTheme.textPrimary,
                             label: Color = AppTheme.textSecondary) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(.title3))
                .foregroundStyle(tint)
                .frame(height: 28)
            Text(title)
                .font(.system(.caption))
                .foregroundStyle(label)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    // MARK: The page

    private var page: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(loc("wallet.recent"))
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(AppTheme.textPrimary)
            if card.isHidden {
                note(loc("wallet.recent_hidden"))
            } else {
                let rows = WalletCard.latest(card.transactions, limit: Self.entries)
                if rows.isEmpty {
                    note(loc("wallet.no_recent"))
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { i, tx in
                            if i > 0 { Rectangle().fill(AppTheme.cardMid).frame(height: 1) }
                            entry(tx)
                        }
                    }
                    .padding(.horizontal, 14)
                    .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
                }
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(.footnote))
            .foregroundStyle(AppTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
    }

    /// One line of the page: what, when, and how much in or out.
    private func entry(_ tx: TxRecord) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tx.name)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                Text(WalletCard.dayLabel(tx.date))
                    .font(.system(.caption))
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(WalletCard.amountText(tx, cardCurrency: card.resolvedCurrency))
                .font(.system(.subheadline, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(tx.amount >= 0 ? AppTheme.green : AppTheme.textPrimary)
                .lineLimit(1).fixedSize()
        }
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }
}
