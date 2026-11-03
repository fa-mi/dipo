import SwiftUI
import SwiftData

// The header at the top of Home, and the card carousel under the total row.

struct HomeHeader: View {
    let vm: AppViewModel
    @Binding var showSearch: Bool
    @Binding var showNotifications: Bool
    /// Opens Ask DiPo. It used to be his face in the reminder row; the row
    /// is now one plain line, so the way in sits with search and news.
    var onAskDiPo: () -> Void = {}
    private var notifMgr: NotificationManager { NotificationManager.shared }

    /// Decoded once and held — not re-decoded on every body pass.
    ///
    /// This was a computed property that pulled the JPEG out of UserDefaults and
    /// ran `UIImage(data:)` *every* time Home re-rendered: every transaction
    /// added, every card swipe, every filter tap. The avatar changes roughly
    /// never, so that work was pure cost on the one screen that must stay smooth.
    @State private var avatar: UIImage? = nil
    @State private var name: String = ""
    /// Observed so the ring changes the moment the plan does.
    @State private var premium = PremiumManager.shared

    private var isRoyal: Bool { premium.plan == .royal }

    /// "Good morning" to "Good night", by the hour.
    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 4..<11:  return loc("home.greeting_morning")
        case 11..<15: return loc("home.greeting_afternoon")
        case 15..<19: return loc("home.greeting_evening")
        default:      return loc("home.greeting_night")
        }
    }

    /// Royal shows as the crown at the photo's edge, and nothing more: the
    /// ring that ran round the photo as well said the same thing twice. Free
    /// has nothing there, so the difference is a badge, not a demotion. The
    /// page's colour round the crown cuts it out of the photo.
    private var avatarRing: some View {
        ZStack(alignment: .bottomTrailing) {
            Color.clear
            if isRoyal {
                Image(systemName: "crown.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(PremiumPlan.royal.color, in: Circle())
                    .padding(2)
                    .background(AppTheme.bg, in: Circle())
                    .offset(x: 5, y: 5)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: 54, height: 54)
    }

    var body: some View {
        HStack(spacing: 12) {
            // Face and name are ONE control, not a decoration beside a label.
            // The name earns its line back by being the title of a button that
            // opens the place where you change the name.
            Button {
                HapticManager.shared.tap()
                vm.openProfile()
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(AppTheme.cardDark)
                            .frame(width: 45, height: 45)
                        if let avatar {
                            Image(uiImage: avatar)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 45, height: 45)
                                .clipShape(Circle())
                        } else {
                            // Without a photo, the header wears DiPo's face.
                            Image("DiPoMascot")
                                .resizable()
                                .scaledToFill()
                                .frame(width: 49, height: 49)
                                .frame(width: 45, height: 45)
                                .clipShape(Circle())
                        }
                        avatarRing
                    }
                    .frame(width: 54, height: 54)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(greeting + ",")
                            .font(.system(.caption))
                            .foregroundStyle(AppTheme.textSecondary)
                        HStack(spacing: 4) {
                            Text(name)
                                .font(.system(.callout, weight: .bold))
                                .foregroundStyle(AppTheme.textPrimary)
                                .lineLimit(1)
                            Image(systemName: "chevron.right")
                                .font(.system(.caption2, weight: .semibold)).imageScale(.small)
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                    }
                }
            }
            .buttonStyle(ScaleButtonStyle())

            Spacer(minLength: 8)

            // Three plain icons, no round tiles behind them: a tile said
            // "button" a second time. Each keeps a 42 pt target.
            HStack(spacing: 4) {
                Button { HapticManager.shared.tap(); onAskDiPo() } label: {
                    headerIcon("bubble.left.and.text.bubble.right")
                }
                .buttonStyle(ScaleButtonStyle())
                .accessibilityLabel(loc("dipo.ask"))

                Button { HapticManager.shared.tap(); showSearch = true } label: {
                    headerIcon("magnifyingglass")
                }
                .accessibilityLabel(loc("a11y.search"))
                .buttonStyle(ScaleButtonStyle())

                Button { HapticManager.shared.tap(); showNotifications = true } label: {
                    ZStack(alignment: .topTrailing) {
                        // Ink when there is news, not green: green says money
                        // coming in. The red count says there is something new.
                        headerIcon(notifMgr.hasUnread ? "bell.badge.fill" : "bell",
                                   ink: notifMgr.hasUnread ? AppTheme.textPrimary : AppTheme.textSecondary)
                            // Rings once when a new notification lands.
                            .symbolEffect(.bounce, value: notifMgr.unreadCount)
                        if notifMgr.unreadCount > 0 {
                            ZStack {
                                Circle().fill(AppTheme.redFill).frame(width: 18, height: 18)
                                Text(notifMgr.unreadCount > 9 ? "9+" : "\(notifMgr.unreadCount)")
                                    .font(.system(.caption2, weight: .bold)).foregroundStyle(AppTheme.onVividFill)
                            }
                            .offset(x: 0, y: 2)
                        }
                    }
                }
                .buttonStyle(ScaleButtonStyle())
                // Read as "Notifications, 3 unread" — the badge digit alone
                // was announced with no noun attached.
                .accessibilityLabel(loc("a11y.notifications"))
                .accessibilityValue(notifMgr.unreadCount > 0
                                    ? String(format: loc("a11y.unread_count"), notifMgr.unreadCount) : "")
            }
        }
        .onAppear(perform: loadIdentity)
        // Every tab stays mounted, so `onAppear` fires once per launch. Editing
        // the name or photo over on Profile has to say so explicitly, or Home
        // would keep greeting the user by their old name until the next launch.
        .onReceive(NotificationCenter.default.publisher(for: .profilePhotoDidChange)) { _ in
            loadIdentity()
        }
    }

    private func headerIcon(_ name: String, ink: Color = AppTheme.textSecondary) -> some View {
        Image(systemName: name)
            .font(.system(.body))
            .foregroundStyle(ink)
            .frame(width: 42, height: 42)
            .contentShape(Rectangle())
    }

    private func loadIdentity() {
        name = Keychain.load(key: "user_name") ?? "User"
        if let data = UserDefaults.standard.data(forKey: "profile_photo") {
            avatar = UIImage(data: data)
        } else {
            avatar = nil
        }
    }
}

// MARK: - Card Carousel

struct CardCarousel: View {
    @Bindable var vm: AppViewModel
    /// The eye on the total row: every card face behind dots.
    var hideAll = false
    var onShowAll: () -> Void = {}

    var body: some View {
        VStack(spacing: 2) {
            TabView(selection: Binding(
                get: { vm.selectedCardIndex },
                set: { vm.selectCard($0) }
            )) {
                ForEach(Array(vm.cards.enumerated()), id: \.element.id) { index, card in
                    BankCardView(card: card, hideAll: hideAll, onShowAll: onShowAll)
                        .padding(.horizontal, 22)
                        .padding(.top, 4)
                        .padding(.bottom, 30)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 216)

            HStack(spacing: 5) {
                ForEach(0..<max(vm.cards.count, 1), id: \.self) { i in
                    Capsule()
                        // Ink, not green: green is kept for the one action.
                        .fill(i == vm.selectedCardIndex ? AppTheme.textPrimary : AppTheme.textSecondary.opacity(0.35))
                        .frame(width: i == vm.selectedCardIndex ? 22 : 6, height: 6)
                        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: vm.selectedCardIndex)
                }
            }
        }
    }
}

// MARK: - Bank Card View

struct BankCardView: View {
    @Bindable var card: BankCard
    /// Home's eye on the total row hides every card at once. The card's own
    /// eye then shows them again, rather than toggling a per-card switch
    /// whose effect the Home-wide one would cover.
    var hideAll = false
    var onShowAll: () -> Void = {}
    @State private var isPressed = false
    /// Drives the balance count-up. Starts at 0 and animates to the real
    /// balance on appear; re-counts smoothly whenever the balance changes.
    @State private var animatedBalance: Double = 0

    private var cardCurrency: String {
        card.currency.isEmpty ? CurrencyManager.shared.preferredCurrency : card.currency
    }

    /// Lifetime total (seed + every tx). Kept around because the negative-
    /// balance warning logic on Home reads from the underlying card
    /// computation — that warning is about overall solvency, not periodic
    /// flow, so it should stay cumulative.
    private var lifetimeBalance: Double {
        let liveBalance = card.transactions.reduce(0.0) { sum, tx in
            sum + CurrencyManager.shared.convert(tx.amount, from: tx.currency, to: cardCurrency)
        }
        return card.balance + liveBalance
    }

    /// The number actually shown on the card face. Shows the card's TOTAL
    /// balance (seed + every transaction, converted to the card currency) so
    /// it matches the Cards tab exactly and can legitimately go negative —
    /// a month-scoped figure hid overspending by resetting to 0 each month.
    /// The Statistics tab remains month-scoped for period analysis.
    // Credit cards show what's OWED, not a cash balance.
    private var totalBalance: Double { card.isCreditCard ? card.owedBalance() : lifetimeBalance }
    private var network: CardNetwork { CardNetwork.detect(from: card.cardNumber) }

    private var formattedBalance: String {
        let abs = Swift.abs(totalBalance)
        return (totalBalance < 0 ? "-" : "") + CurrencyManager.shared.formatted(abs, currency: cardCurrency)
    }

    private var masked: Bool { card.isHidden || hideAll }

    private var gradient: LinearGradient {
        LinearGradient(colors: [Color(hex: card.gradientStart), Color(hex: card.gradientEnd)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// The face: the card's own gradient, flat, like the cards in the
    /// wallet. The light it used to carry — a glow at the top right, shade
    /// at the bottom left, a sheen, a rim and a coloured glow under the card —
    /// was decoration on the thing that shows real money.
    private var face: some View {
        RoundedRectangle(cornerRadius: AppRadius.xl).fill(gradient)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            face

            // Mockup order, and the right order: the balance is the reason
            // anyone looks at this card, so it sits at the top where the eye
            // lands. Identity (whose card, which number, when it expires) is
            // what you check second, so it moves to the bottom.
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    HStack(spacing: 8) {
                        Text(card.isCreditCard ? loc("cc.owed") : loc("home.balance_total"))
                            .font(.system(.caption2, weight: .medium))
                            .foregroundStyle(.white.opacity(0.75))
                        Button {
                            HapticManager.shared.tap()
                            if hideAll { onShowAll() } else { card.isHidden.toggle() }
                        } label: {
                            Image(systemName: masked ? "eye.slash" : "eye")
                                .font(.system(.caption, weight: .medium))
                                .foregroundStyle(.white.opacity(0.7))
                        }
.accessibilityLabel(loc(masked ? "a11y.show_balance" : "a11y.hide_balance"))
                        .buttonStyle(ScaleButtonStyle())
                    }
                    Spacer()
                    if card.isDigitalWallet, let wp = WalletProvider(rawValue: card.walletProvider) {
                        HStack(spacing: 4) {
                            Image(systemName: wp.icon)
                                .font(.system(.caption, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.9))
                            Text(loc("cards.digital_wallet"))
                                .font(.system(.caption2, weight: .medium))
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    } else {
                        CardNetworkLogo(network: network)
                    }
                }

                // Hidden → static dots. Visible → CountUpText that rolls the
                // number up on appear and re-counts whenever it changes.
                Group {
                    if masked {
                        Text("••••••")
                    } else {
                        CountUpText(value: animatedBalance, currency: cardCurrency)
                    }
                }
                .font(.system(.title, weight: .bold))
                .foregroundStyle(totalBalance < 0 && !masked ? AppTheme.red : .white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.top, 8)
                .onAppear {
                    withAnimation(.easeOut(duration: 0.9)) { animatedBalance = totalBalance }
                }
                .onChange(of: totalBalance) { _, newValue in
                    withAnimation(.easeOut(duration: 0.55)) { animatedBalance = newValue }
                }

                if totalBalance < 0 && !masked {
                    Text(loc("home.negative"))
                        .font(.system(.caption2, weight: .semibold))
                        .foregroundStyle(AppTheme.red.opacity(0.9))
                        .padding(.top, 2)
                }

                Spacer(minLength: 8)

                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(card.holderName)
                            .font(.system(.caption, weight: .medium))
                            .foregroundStyle(.white.opacity(0.92))
                            .lineLimit(1)
                        // Currency joins the number. On a single-currency
                        // wallet it is redundant; the moment a second currency
                        // exists it is the difference between two cards whose
                        // digits look alike.
                        Text("\(cardCurrency) · \(card.isDigitalWallet ? card.displayPhone : card.displayNumber)")
                            .font(.system(.caption2))
                            .foregroundStyle(.white.opacity(0.65))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 10)
                    if !card.isDigitalWallet {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(loc("cards.expires"))
                                .font(.system(.caption2)).foregroundStyle(.white.opacity(0.6))
                            Text(card.expireDate)
                                .font(.system(.footnote, weight: .semibold)).foregroundStyle(.white)
                        }
                    }
                }
            }
            .padding(20)
        }
        .frame(height: 182)
        .scaleEffect(isPressed ? 0.97 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isPressed)
        .onLongPressGesture(minimumDuration: .infinity, pressing: { p in
            isPressed = p
            if p { HapticManager.shared.tap() }
        }, perform: {})
    }
}
