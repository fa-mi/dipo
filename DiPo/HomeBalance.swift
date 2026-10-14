import SwiftUI

// MARK: - Home: the money first
//
// Home opens on the total the user holds, then their accounts side by side,
// then DiPo's one line. DiPo used to stand above all of it, a 3D figure with
// a thought cloud, and took the top of the screen before any money did; the
// big swipeable card showed one account at a time, so the total was never on
// screen at all.

/// Home's preferences. Kept on this device, like the appearance mode: they
/// are choices about one screen, not records worth a backup.
enum HomePrefs {
    /// DiPo's face on Home: his row and the header's stand-in avatar. Off, a
    /// plain icon and the user's initial take his places.
    static let showDiPoKey = "home_show_dipo"
    /// Every figure on Home behind dots, from the eye beside the total.
    static let hideBalancesKey = "home_hide_balances"
}

/// The words under the total: what is left of this period's money and how
/// long until payday. Worked out here, away from the view, so the rules can
/// be tested and so nothing is said that the period card would contradict.
struct HomeHeroLine: Equatable {
    enum Left: Equatable {
        /// What is left of the period's income.
        case left(Double)
        /// How far living costs went past it — said as that, never as a minus.
        case over(Double)
    }
    var left: Left? = nil
    var payday: String? = nil

    /// - Parameters: the period card's own figures for the main card's pot.
    ///   With no income or added money yet, nothing is "left of" anything,
    ///   so only the payday is said.
    static func make(income: Double, expense: Double, putAway: Double, extra: Double,
                     daysToPayday: Int?) -> HomeHeroLine {
        var line = HomeHeroLine()
        if income + extra >= 0.5 {
            let rest = MonthFlowCard.remaining(income: income, expense: expense, putAway: putAway, extra: extra)
            line.left = rest >= -0.5 ? .left(max(rest, 0)) : .over(-rest)
        }
        if let days = daysToPayday, days >= 0 {
            switch days {
            case 0:  line.payday = loc("home.hero.payday_today")
            case 1:  line.payday = loc("home.hero.payday_tomorrow")
            default: line.payday = String(format: loc("home.hero.payday_in"), days)
            }
        }
        return line
    }
}

/// The total at the top of Home: every cash account added up in the
/// preferred currency. Credit cards are left out — what is owed on them is
/// not money held — as Net Worth already does.
struct HomeBalanceHero: View {
    let total: Double
    let currency: String
    let line: HomeHeroLine
    /// A salary schedule makes the window a pay cycle; without one it is the
    /// calendar month, and the words say which.
    let hasCycle: Bool
    @Binding var hidden: Bool

    private func money(_ v: Double) -> String { CurrencyManager.shared.formatted(v, currency: currency) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(loc("home.total_balance").uppercased(with: LanguageManager.shared.currentLocale))
                    .font(.system(.caption, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(AppTheme.textSecondary)
                Button {
                    HapticManager.shared.tap()
                    withAnimation(.easeOut(duration: 0.2)) { hidden.toggle() }
                } label: {
                    Image(systemName: hidden ? "eye.slash" : "eye")
                        .font(.system(.caption, weight: .semibold))
                        .foregroundStyle(AppTheme.textSecondary)
                        .frame(width: 28, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ScaleButtonStyle())
                .accessibilityLabel(loc(hidden ? "home.show_all" : "home.hide_all"))
            }

            Text(hidden ? "••••••" : (total < 0 ? "-" : "") + money(Swift.abs(total)))
                .font(.system(.largeTitle, weight: .bold).monospacedDigit())
                .foregroundStyle(total < 0 && !hidden ? AppTheme.red : AppTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.45), value: total)
                .accessibilityLabel(loc("home.total_balance"))
                // Hidden means not read out either.
                .accessibilityValue(hidden ? "" : (total < 0 ? "-" : "") + money(Swift.abs(total)))

            if let words = subtitle {
                Text(words)
                    .font(.system(.footnote))
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "Left this period Rp 1.896.515 · 11 days to payday", the amount in
    /// green (or orange when income is passed). Built as one attributed
    /// string so it wraps as a sentence.
    private var subtitle: AttributedString? {
        var parts: [AttributedString] = []
        if let left = line.left, !hidden {
            let label: String, amount: Double, tint: Color
            switch left {
            case .left(let v): label = loc(hasCycle ? "home.hero.left" : "home.hero.left_month"); amount = v; tint = AppTheme.accent
            case .over(let v): label = loc("home.hero.over"); amount = v; tint = AppTheme.orange
            }
            // SwiftUI's own attributes, named: UIKit has a foregroundColor too.
            var figure = AttributedString(money(amount))
            figure[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] = tint
            figure[AttributeScopes.SwiftUIAttributes.FontAttribute.self] = Font.system(.footnote, weight: .bold)
            parts.append(AttributedString(label + " ") + figure)
        }
        if let payday = line.payday { parts.append(AttributedString(payday)) }
        guard var out = parts.first else { return nil }
        for part in parts.dropFirst() { out += AttributedString(" · ") + part }
        return out
    }
}

// MARK: - Accounts, side by side

/// The accounts under the total, small and side by side; it scrolls past two.
/// Tapping one chooses it for the period card and the list below, as swiping
/// the big card did. Holding one hides its balance or opens card management.
struct HomeAccountTiles: View {
    @Bindable var vm: AppViewModel
    var hideAll: Bool
    var onAdd: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(Array(vm.cards.enumerated()), id: \.element.id) { index, card in
                    Button {
                        vm.selectCard(index)
                    } label: {
                        HomeAccountTile(card: card, selected: index == vm.selectedCardIndex, hideAll: hideAll)
                    }
                    .buttonStyle(ScaleButtonStyle())
                    .contextMenu {
                        Button {
                            card.isHidden.toggle()
                        } label: {
                            Label(loc(card.isHidden ? "a11y.show_balance" : "a11y.hide_balance"),
                                  systemImage: card.isHidden ? "eye" : "eye.slash")
                        }
                        Button {
                            vm.showCardManager = true
                        } label: {
                            Label(loc("home.manage_cards"), systemImage: "creditcard")
                        }
                    }
                }
                Button {
                    HapticManager.shared.tap()
                    onAdd()
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "plus").font(.system(.title3, weight: .semibold))
                        Text(loc("home.add_account")).font(.system(.caption, weight: .medium))
                    }
                    .foregroundStyle(AppTheme.textSecondary)
                    .frame(width: 92, height: HomeAccountTile.height)
                    .overlay(RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                        .strokeBorder(AppTheme.textSecondary.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
                }
                .buttonStyle(ScaleButtonStyle())
                .accessibilityLabel(loc("cards.add_card"))
            }
            // Room for the selected tile's ring, which sits outside it.
            .padding(.horizontal, 22).padding(.vertical, 5)
        }
    }
}

/// One account on Home: which it is, and what it holds (or, for a credit
/// card, what is owed on it). The card's own colours, as on the big card.
struct HomeAccountTile: View {
    @Bindable var card: BankCard
    let selected: Bool
    let hideAll: Bool

    static let width: CGFloat = 164
    static let height: CGFloat = 92

    private var masked: Bool { hideAll || card.isHidden }
    private var amount: Double { card.isCreditCard ? card.owedBalance() : card.computedBalance() }
    private var amountText: String {
        (amount < 0 ? "-" : "") + CurrencyManager.shared.formatted(Swift.abs(amount), currency: card.resolvedCurrency)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                if card.isDigitalWallet, let wp = WalletProvider(rawValue: card.walletProvider) {
                    Image(systemName: wp.icon)
                } else if card.isCreditCard {
                    Image(systemName: "creditcard.fill")
                }
                Text(card.tileLabel).lineLimit(1)
            }
            .font(.system(.caption, weight: .semibold))
            .foregroundStyle(.white.opacity(0.92))

            Spacer(minLength: 4)

            if card.isCreditCard {
                Text(loc("cc.owed"))
                    .font(.system(.caption2, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
            }
            HStack(spacing: 4) {
                // A minus on a card face is easy to miss; the mark is not.
                if amount < 0, !masked, !card.isCreditCard {
                    Image(systemName: "exclamationmark.circle.fill").font(.system(.footnote))
                }
                Text(masked ? "••••••" : amountText)
                    .font(.system(.title3, weight: .bold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
            }
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(width: Self.width, height: Self.height, alignment: .leading)
        .background {
            shape.fill(LinearGradient(colors: [Color(hex: card.gradientStart), Color(hex: card.gradientEnd)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(shape.fill(LinearGradient(colors: [Color.white.opacity(0.16), .clear],
                                                   startPoint: .top, endPoint: .center)))
                .overlay(shape.strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
        }
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: AppRadius.lg + 4, style: .continuous)
                    .strokeBorder(AppTheme.accent, lineWidth: 2)
                    .padding(-4)
            }
        }
        .animation(.spring(response: 0.3), value: selected)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(card.tileLabel)
        .accessibilityValue(masked ? "" : (card.isCreditCard ? loc("cc.owed") + " " : "") + amountText)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

extension BankCard {
    /// The short name a tile on Home carries: the bank or wallet, then the
    /// last four digits ("BRI •• 0969"). The issuer the user picked comes
    /// first, then one detected from the number, then the holder name.
    var tileLabel: String {
        if isDigitalWallet {
            return walletProvider.isEmpty ? (holderName.isEmpty ? loc("card.untitled") : holderName) : walletProvider
        }
        let last4 = String(cardNumber.filter(\.isNumber).suffix(4))
        let name = (BankIssuer.find(issuerID) ?? BankIssuer.detect(from: cardNumber))?.name ?? holderName
        if name.isEmpty { return last4.isEmpty ? loc("card.untitled") : "•• \(last4)" }
        return last4.isEmpty ? name : "\(name) •• \(last4)"
    }
}
