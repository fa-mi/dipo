import SwiftUI
import SwiftData

// Moved out of HomeView.swift, unchanged. The header and the card carousel at the top of Home.

struct HomeHeader: View {
    let vm: AppViewModel
    @Binding var showSearch: Bool
    @Binding var showNotifications: Bool
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

    /// Royal wears its colour as a ring — purple running into a warm gold, the
    /// crown's own pairing — with the crown tucked at the edge. Free keeps a
    /// quiet hairline, so the difference is a badge, not a demotion.
    private var avatarRing: some View {
        ZStack(alignment: .bottomTrailing) {
            if isRoyal {
                Circle()
                    .strokeBorder(AngularGradient(colors: [PremiumPlan.royal.color, Color(hex: "#E879F9"),
                                                           Color(hex: "#FBBF24"), PremiumPlan.royal.color],
                                                  center: .center, angle: .degrees(-60)),
                                  lineWidth: 2.5)
                Image(systemName: "crown.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(PremiumPlan.royal.color, in: Circle())
                    .overlay(Circle().stroke(AppTheme.bg, lineWidth: 2))
                    .offset(x: 3, y: 3)
                    .accessibilityHidden(true)
            } else {
                Circle().strokeBorder(AppTheme.cardMid, lineWidth: 1.5)
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
                            .fill(LinearGradient(colors: [AppTheme.cardMid, AppTheme.cardDark],
                                                startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 45, height: 45)
                        if let avatar {
                            Image(uiImage: avatar)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 45, height: 45)
                                .clipShape(Circle())
                        } else {
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
                        Text(loc("home.greeting") + ",")
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

            HStack(spacing: 14) {
                Button { HapticManager.shared.tap(); showSearch = true } label: {
                    ZStack {
                        Circle().fill(AppTheme.cardDark).frame(width: 42, height: 42)
                        Image(systemName: "magnifyingglass").font(.system(.body)).foregroundStyle(AppTheme.textSecondary)
                    }
                }
.accessibilityLabel(loc("a11y.search"))
                .buttonStyle(ScaleButtonStyle())

                Button { HapticManager.shared.tap(); showNotifications = true } label: {
                    ZStack(alignment: .topTrailing) {
                        ZStack {
                            Circle().fill(AppTheme.cardDark).frame(width: 42, height: 42)
                            Image(systemName: notifMgr.hasUnread ? "bell.badge.fill" : "bell")
                                .font(.system(.body))
                                .foregroundStyle(notifMgr.hasUnread ? AppTheme.accent : AppTheme.textSecondary)
                                // Rings once when a new notification lands.
                                .symbolEffect(.bounce, value: notifMgr.unreadCount)
                        }
                        if notifMgr.unreadCount > 0 {
                            ZStack {
                                Circle().fill(AppTheme.redFill).frame(width: 18, height: 18)
                                Text(notifMgr.unreadCount > 9 ? "9+" : "\(notifMgr.unreadCount)")
                                    .font(.system(.caption2, weight: .bold)).foregroundStyle(AppTheme.onVividFill)
                            }
                            .offset(x: 4, y: -4)
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

    var body: some View {
        VStack(spacing: 2) {
            TabView(selection: Binding(
                get: { vm.selectedCardIndex },
                set: { vm.selectCard($0) }
            )) {
                ForEach(Array(vm.cards.enumerated()), id: \.element.id) { index, card in
                    BankCardView(card: card)
                        .padding(.horizontal, 22)
                        // The page clips its content, so the glow under the card
                        // needs room inside it — the old black shadow was cut
                        // off flat along the bottom edge.
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
                        .fill(i == vm.selectedCardIndex ? AppTheme.accent : AppTheme.textSecondary.opacity(0.35))
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
    @Environment(\.colorScheme) private var colorScheme
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

    private var gradient: LinearGradient {
        LinearGradient(colors: [Color(hex: card.gradientStart), Color(hex: card.gradientEnd)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// The face: the card's own gradient, lit like a surface rather than
    /// painted flat — a soft glow from the top right, depth pooling at the
    /// bottom left, a light sheen across the top and a hairline edge that
    /// catches it. The network's colour still tints the corner curve.
    ///
    /// Gone: a black drop shadow (it clipped flat against the carousel page
    /// and read as a smudge in dark mode) and a sparkline drawn from a fixed
    /// array of numbers — a chart of nothing, on the card showing real money.
    private var face: some View {
        ZStack {
            RoundedRectangle(cornerRadius: AppRadius.xl).fill(gradient)

            GeometryReader { g in
                let w = g.size.width, h = g.size.height
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.22))
                        .frame(width: w * 0.75, height: w * 0.75)
                        .blur(radius: 38)
                        .offset(x: w * 0.42, y: -h * 0.55)
                    Circle()
                        .fill(Color.black.opacity(0.22))
                        .frame(width: w * 0.7, height: w * 0.7)
                        .blur(radius: 44)
                        .offset(x: -w * 0.42, y: h * 0.62)
                    Path { p in
                        p.move(to: .init(x: w * 0.46, y: 0))
                        p.addCurve(to: .init(x: w, y: h * 0.62),
                                   control1: .init(x: w * 0.8, y: -8),
                                   control2: .init(x: w + 6, y: h * 0.3))
                        p.addLine(to: .init(x: w, y: 0))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [network.accentColor.opacity(0.28), network.accentColor.opacity(0.02)],
                                         startPoint: .top, endPoint: .bottom))
                    LinearGradient(colors: [Color.white.opacity(0.16), .clear],
                                   startPoint: .top, endPoint: .center)
                }
                .frame(width: w, height: h)
            }
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.xl))

            RoundedRectangle(cornerRadius: AppRadius.xl)
                .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.45), Color.white.opacity(0.06),
                                                      Color.white.opacity(0.18)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing),
                              lineWidth: 1)
        }
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
                            card.isHidden.toggle()
                        } label: {
                            Image(systemName: card.isHidden ? "eye.slash" : "eye")
                                .font(.system(.caption, weight: .medium))
                                .foregroundStyle(.white.opacity(0.7))
                        }
.accessibilityLabel(loc(card.isHidden ? "a11y.show_balance" : "a11y.hide_balance"))
                        .buttonStyle(ScaleButtonStyle())
                    }
                    Spacer()
                    if !card.isDigitalWallet {
                        Image(systemName: "wave.3.right")
                            .font(.system(.caption, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                            .padding(.trailing, 8)
                            .padding(.top, 3)
                            .accessibilityHidden(true)
                    }
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
                    if card.isHidden {
                        Text("••••••")
                    } else {
                        CountUpText(value: animatedBalance, currency: cardCurrency)
                    }
                }
                .font(.system(.title, weight: .bold))
                .foregroundStyle(totalBalance < 0 ? AppTheme.red : .white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.top, 8)
                .onAppear {
                    withAnimation(.easeOut(duration: 0.9)) { animatedBalance = totalBalance }
                }
                .onChange(of: totalBalance) { _, newValue in
                    withAnimation(.easeOut(duration: 0.55)) { animatedBalance = newValue }
                }

                if totalBalance < 0 && !card.isHidden {
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
        // A glow in the card's own colours, not a black shadow: it lifts the
        // card off the page in both themes and belongs to the card it sits under.
        .background(alignment: .bottom) {
            RoundedRectangle(cornerRadius: AppRadius.xl)
                .fill(gradient)
                .frame(height: 150)
                .padding(.horizontal, 20)
                .offset(y: 14)
                .blur(radius: 20)
                .opacity(colorScheme == .dark ? 0.55 : 0.45)
        }
        .scaleEffect(isPressed ? 0.97 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isPressed)
        .onLongPressGesture(minimumDuration: .infinity, pressing: { p in
            isPressed = p
            if p { HapticManager.shared.tap() }
        }, perform: {})
    }
}
