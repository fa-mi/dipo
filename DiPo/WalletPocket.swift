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

struct WalletPocket: View {
    let cards: [BankCard]
    var onOpen: (BankCard) -> Void

    /// How much of each card shows above the next one. Scaled with the text
    /// on it, so a larger size does not push the figures under the next card.
    @ScaledMetric(relativeTo: .headline) private var strip: CGFloat = 64
    /// How much of the front card shows above the pocket's sides.
    @ScaledMetric(relativeTo: .headline) private var front: CGFloat = 104
    /// How far the pocket's lip dips in the middle.
    static let dip: CGFloat = 26

    private var stackHeight: CGFloat { CGFloat(max(cards.count - 1, 0)) * strip + front }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                ForEach(Array(cards.enumerated()), id: \.element.id) { i, card in
                    Button { onOpen(card) } label: {
                        // Its own height for the width, not the stack's: the
                        // stack is shorter than a card and would shrink it.
                        WalletPocketCard(card: card, isFront: i == cards.count - 1, strip: strip)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .buttonStyle(.plain)
                    .offset(y: CGFloat(i) * strip)
                    .zIndex(Double(i))
                }
            }
            // The front card runs on under the pocket; it ends at the lip's
            // lowest point, so a short pocket never shows its lower edge. The
            // mask reaches past the sides and the top to keep the shadows.
            .frame(height: stackHeight + Self.dip, alignment: .top)
            .mask { Rectangle().padding(.horizontal, -24).padding(.top, -24) }

            WalletPocketFace(totals: Self.totals(of: cards, preferred: CurrencyManager.shared.preferredCurrency))
                .padding(.top, -Self.dip)
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
/// the pocket, so that is where everything it has to say goes.
struct WalletPocketCard: View {
    let card: BankCard
    /// The card at the front shows more than its strip, so it carries the
    /// principal there, where a real card prints it.
    var isFront = false
    /// How tall the strip is, for where the principal goes on the front card.
    var strip: CGFloat = 64

    @Environment(\.colorScheme) private var colorScheme
    /// Observed so the main-card mark moves the moment the choice changes.
    @State private var sb = SmartBudgetManager.shared

    /// ID-1, lying down.
    static let aspect: CGFloat = 85.6 / 53.98

    private var network: CardNetwork { CardNetwork.detect(from: card.cardNumber) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            WalletCardFace.gradient(for: card)
            VStack(spacing: 0) {
                WalletCardFace.header(card, isMain: WalletCardFace.isMain(card, sb), figures: true)
                if isFront && !card.isDigitalWallet && network != .unknown {
                    HStack {
                        Spacer(minLength: 0)
                        CardNetworkLogo(network: network)
                            .scaleEffect(0.8, anchor: .topTrailing)
                            .accessibilityHidden(true)
                    }
                    .padding(.top, max(strip - 54, 4))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 15).padding(.top, 12)
        }
        .aspectRatio(Self.aspect, contentMode: .fit)
        .clipShape(WalletCardFace.shape)
        .overlay(WalletCardFace.shape.strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
        // Cast upward, onto the card behind: that is what tells the edges apart.
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.18), radius: 8, y: -3)
        .contentShape(WalletCardFace.shape)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - The pocket

/// The pocket's face: the total cash, and what the credit cards owe.
struct WalletPocketFace: View {
    let totals: (cash: [WalletPocket.Amount], bills: [WalletPocket.Amount])
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(loc("wallet.total_cash"))
                .font(.system(.footnote))
                .foregroundStyle(AppTheme.textSecondary)
            if totals.cash.isEmpty {
                figure(WalletPocket.Amount(currency: CurrencyManager.shared.preferredCurrency, value: 0), lead: true)
            }
            ForEach(Array(totals.cash.enumerated()), id: \.element.currency) { i, item in
                figure(item, lead: i == 0)
            }
            if !totals.bills.isEmpty {
                Rectangle().fill(AppTheme.cardMid).frame(height: 1).padding(.top, 12)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(loc("wallet.cc_bills"))
                        .font(.system(.footnote))
                        .foregroundStyle(AppTheme.textSecondary)
                    Spacer(minLength: 8)
                    Text(totals.bills.map { CurrencyManager.shared.formatted($0.value, currency: $0.currency) }
                        .joined(separator: " · "))
                        .font(.system(.footnote, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                .padding(.top, 10)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, WalletPocket.dip + 16)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            WalletPocketShape(dip: WalletPocket.dip)
                .fill(AppTheme.cardDark)
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.45 : 0.16), radius: 8, y: -4)
        }
        .overlay {
            WalletPocketStitch(dip: WalletPocket.dip)
                .stroke(AppTheme.textSecondary.opacity(0.45), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
        }
        .accessibilityElement(children: .combine)
    }

    /// One currency's total: the first large, any other one under it smaller.
    private func figure(_ item: WalletPocket.Amount, lead: Bool) -> some View {
        Text((item.value < 0 ? "-" : "")
             + CurrencyManager.shared.formatted(Swift.abs(item.value), currency: item.currency))
            .font(.system(lead ? .title : .headline, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(item.value < 0 ? AppTheme.red : AppTheme.accent)
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
        let radius: CGFloat = 16   // AppRadius.md, a card's inner corner
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

/// The stitching along the pocket's lip.
struct WalletPocketStitch: Shape {
    var dip: CGFloat
    var inset: CGFloat = 8

    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX + inset, y: r.minY + inset))
        WalletPocketShape.lip(&p, from: r.minX + inset, to: r.maxX - inset, y: r.minY + inset, dip: dip)
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
    /// in it on the right.
    static func header(_ card: BankCard, isMain: Bool, figures: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(WalletCard.title(for: card))
                        .font(.system(.headline, weight: .bold))
                        .lineLimit(1).minimumScaleFactor(0.7)
                    if isMain { mainChip }
                }
                let sub = WalletCard.subtitle(for: card)
                if !sub.isEmpty {
                    Text(sub)
                        .font(.system(.caption))
                        .foregroundStyle(.white.opacity(0.78))
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
                    Text(amountLabel(card))
                        .font(.system(.caption))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(1)
                }
                .layoutPriority(1)
            }
        }
        .foregroundStyle(.white)
    }

    static var mainChip: some View {
        Label(loc("main.badge"), systemImage: "star.fill")
            .font(.system(.caption2, weight: .semibold))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.white.opacity(0.22), in: Capsule())
            .lineLimit(1).fixedSize()
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
    @Environment(\.colorScheme) private var colorScheme
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
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.14), radius: 10, y: 6)
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
                    actionLabel("star.fill", loc("main.badge"), fill: AppTheme.accentFill, tint: AppTheme.bg)
                        .accessibilityLabel(loc("main.is_main"))
                } else {
                    Button {
                        HapticManager.shared.success()
                        withAnimation(AppMotion.move) { MainCard.set(card) }
                    } label: {
                        actionLabel("star", loc("wallet.act_main"), fill: AppTheme.accent.opacity(0.12), tint: AppTheme.accent)
                    }
                    .buttonStyle(ScaleButtonStyle())
                    .accessibilityLabel(loc("main.make_main"))
                }
                Button {
                    HapticManager.shared.tap()
                    showMatchBalance = true
                } label: {
                    actionLabel("equal.circle", loc("wallet.act_match"), fill: AppTheme.cardDark, tint: AppTheme.textSecondary)
                }
                .buttonStyle(ScaleButtonStyle())
                .accessibilityLabel(loc("match.title"))
            }
            Button {
                HapticManager.shared.tap()
                onEdit()
            } label: {
                actionLabel("pencil", loc("common.edit"), fill: AppTheme.cardDark, tint: AppTheme.textSecondary)
            }
            .buttonStyle(ScaleButtonStyle())
            Button {
                HapticManager.shared.warning()
                onDelete()
            } label: {
                actionLabel("trash", loc("common.delete"), fill: AppTheme.red.opacity(0.12), tint: AppTheme.red, label: AppTheme.red)
            }
            .buttonStyle(ScaleButtonStyle())
        }
    }

    private func actionLabel(_ icon: String, _ title: String, fill: Color, tint: Color,
                             label: Color = AppTheme.textPrimary) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(.body, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 48, height: 48)
                .background(fill, in: Circle())
            Text(title)
                .font(.system(.caption))
                .foregroundStyle(label)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
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
