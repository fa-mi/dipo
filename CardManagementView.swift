import SwiftUI
import SwiftData



// MARK: - Card Type Detection

// MARK: - Digital Wallet Providers

enum WalletProvider: String, CaseIterable, Identifiable {
    case gopay   = "GoPay"
    case ovo     = "OVO"
    case dana    = "DANA"
    case jenius  = "Jenius"
    case blu     = "blu by BCA"
    case seabank = "SeaBank"
    case neobank = "Neo Bank"
    case linkaja = "LinkAja"
    case paypal  = "PayPal"
    case other   = "Other"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .gopay:   return "g.circle.fill"
        case .ovo:     return "o.circle.fill"
        case .dana:    return "d.circle.fill"
        case .jenius:  return "j.circle.fill"
        case .blu:     return "b.circle.fill"
        case .seabank: return "s.circle.fill"
        case .neobank: return "n.circle.fill"
        case .linkaja: return "l.circle.fill"
        case .paypal:  return "p.circle.fill"
        case .other:   return "creditcard.fill"
        }
    }

    var color: Color {
        switch self {
        case .gopay:   return Color(hex: "#00AED6")
        case .ovo:     return Color(hex: "#4C3494")
        case .dana:    return Color(hex: "#118EEA")
        case .jenius:  return Color(hex: "#00B9F2")
        case .blu:     return Color(hex: "#0070B8")
        case .seabank: return Color(hex: "#F97316")
        case .neobank: return Color(hex: "#FFCD00")
        case .linkaja: return Color(hex: "#E8192C")
        case .paypal:  return Color(hex: "#009CDE")
        case .other:   return Color(hex: "#5A5E72")
        }
    }

    var gradientStart: String {
        switch self {
        case .gopay:   return "#00AED6"
        case .ovo:     return "#4C3494"
        case .dana:    return "#118EEA"
        case .jenius:  return "#00B9F2"
        case .blu:     return "#0070B8"
        case .seabank: return "#E8580A"
        case .neobank: return "#F5C500"
        case .linkaja: return "#E8192C"
        case .paypal:  return "#003087"
        case .other:   return "#2A3330"
        }
    }

    var gradientEnd: String {
        switch self {
        case .gopay:   return "#006E8A"
        case .ovo:     return "#2D1D5E"
        case .dana:    return "#0A5DA4"
        case .jenius:  return "#007FAA"
        case .blu:     return "#003D7A"
        case .seabank: return "#C2400A"
        case .neobank: return "#C9A000"
        case .linkaja: return "#8C0A14"
        case .paypal:  return "#009CDE"
        case .other:   return "#1A2028"
        }
    }
}

enum CardNetwork {
    case visa, mastercard, unknown

    static func detect(from number: String) -> CardNetwork {
        let digits = number.replacingOccurrences(of: " ", with: "")
        guard let first = digits.first else { return .unknown }
        switch first {
        case "4": return .visa
        case "5": return .mastercard
        default:  return .unknown
        }
    }

    var name: String {
        switch self {
        case .visa:       return "VISA"
        case .mastercard: return "Mastercard"
        case .unknown:    return "Card"
        }
    }

    var gradientStart: String {
        switch self {
        case .visa:       return "#1A3A8F"   // Visa royal blue
        case .mastercard: return "#1A1A1A"   // Mastercard near-black
        case .unknown:    return "#2A3330"
        }
    }

    var gradientEnd: String {
        switch self {
        case .visa:       return "#0D2461"   // Visa deep blue
        case .mastercard: return "#0D0D0D"
        case .unknown:    return "#1A2028"
        }
    }

    var accentColor: Color {
        switch self {
        case .visa:       return Color(hex: "#4D8EFF")   // Visa blue accent
        case .mastercard: return Color(hex: "#F79E1B")   // Mastercard orange
        case .unknown:    return Color(hex: "#8A9693")
        }
    }
}

// MARK: - Card List View (CRUD)

struct CardListView: View {
    @Bindable var vm: AppViewModel
    @Environment(\.modelContext) private var modelContext
    // Needed for the cascade below — deleting a card must take its dependents
    // with it, or they linger pointing at something that no longer exists.
    @Query private var allSchedules: [SalarySchedule]
    @Query private var allRecurrings: [RecurringExpense]
    @Query private var allBudgetConfigs: [CardBudgetConfig]
    @State private var showAddCard    = false
    @State private var editingCard: BankCard? = nil
    @State private var appeared       = false
    @State private var showTransfer        = false
    @State private var showTransferPaywall = false
    @State private var pm = PremiumManager.shared
    /// Which card the carousel is centred on. Drives the actions beneath it.
    @State private var carouselID: UUID? = nil
    @State private var deletingCard: BankCard? = nil


    /// Kelompokkan saldo per mata uang kartu. Tiap kartu dijumlah dalam currency-nya sendiri
    /// sehingga IDR tidak dicampur dengan USD — display jujur tanpa estimasi kurs.
    private var balancePerCurrency: [(currency: String, total: Double)] {
        var dict: [String: Double] = [:]
        // Credit cards are liabilities, not cash — exclude them from the cash
        // totals shown here (they appear as owed in the Debt Tracker instead).
        for card in vm.cards where !card.isCreditCard {
            let cardCur = card.currency.isEmpty
                ? CurrencyManager.shared.preferredCurrency
                : card.currency
            let txBalance = card.transactions.reduce(0.0) { sum, tx in
                sum + CurrencyManager.shared.convert(tx.amount, from: tx.currency, to: cardCur)
            }
            dict[cardCur, default: 0] += card.balance + txBalance
        }
        // Urutkan: preferred currency dulu, sisanya alphabetical
        let preferred = CurrencyManager.shared.preferredCurrency
        return dict.sorted { a, b in
            if a.key == preferred { return true }
            if b.key == preferred { return false }
            return a.key < b.key
        }.map { (currency: $0.key, total: $0.value) }
    }

    /// Same cascade CardDetailRow used to perform. A card's salary schedules,
    /// recurring plans and per-card budget config are meaningless once it is
    /// gone, and a budget scoped to it would silently widen to "all cards"
    /// while the settings still claimed a card scope.
    private func deleteCard(_ card: BankCard) {
        for s in allSchedules where s.cardID == card.id { modelContext.delete(s) }
        for r in allRecurrings where r.cardID == card.id { modelContext.delete(r) }
        for cfg in allBudgetConfigs where cfg.cardID == card.id.uuidString { modelContext.delete(cfg) }
        if SmartBudgetManager.shared.budgetCardID == card.id.uuidString {
            SmartBudgetManager.shared.budgetCardID = nil
        }
        let nextID = vm.cards.first(where: { $0.id != card.id })?.id
        modelContext.delete(card)          // cascade removes its transactions
        try? modelContext.save()
        HapticManager.shared.warning()
        carouselID = nextID
    }

    var body: some View {
        ZStack {
            AppTheme.bg.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    // Header
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(loc("wallet.title"))
                                .font(.system(size: 24, weight: .bold))
                                .foregroundStyle(AppTheme.textPrimary)
                            Text(String(format: loc(vm.cards.count == 1 ? "cards.card_count" : "cards.card_counts"), vm.cards.count))
                                .font(.system(size: 13))
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                        Spacer()
                        HStack(spacing: 12) {
                            // Transfer between cards — Royal-only. Needs ≥2 cards
                            // to have somewhere to move money to.
                            if vm.cards.count >= 2 {
                                Button {
                                    HapticManager.shared.tap()
                                    let _ = pm.plan
                                    if pm.canAccess(.cardTransfer) {
                                        showTransfer = true
                                    } else {
                                        showTransferPaywall = true
                                    }
                                } label: {
                                    ZStack {
                                        Circle()
                                            .fill(AppTheme.cardDark)
                                            .frame(width: 42, height: 42)
                                            .overlay(Circle().stroke(AppTheme.accent.opacity(0.3), lineWidth: 1))
                                        Image(systemName: "arrow.left.arrow.right")
                                            .font(.system(size: 16, weight: .semibold))
                                            .foregroundStyle(AppTheme.accent)
                                        if !pm.canAccess(.cardTransfer) {
                                            Image(systemName: "crown.fill")
                                                .font(.system(size: 8, weight: .bold))
                                                .foregroundStyle(.white)
                                                .padding(3)
                                                .background(PremiumPlan.royal.color, in: Circle())
                                                .offset(x: 15, y: -15)
                                        }
                                    }
                                }
                                .buttonStyle(ScaleButtonStyle())
                            }
                            Button {
                                HapticManager.shared.tap()
                                showAddCard = true
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(AppTheme.accent)
                                        .frame(width: 42, height: 42)
                                        .shadow(color: AppTheme.accent.opacity(0.4), radius: 10, y: 4)
                                    Image(systemName: "plus")
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundStyle(AppTheme.bg)
                                }
                            }
                            .buttonStyle(ScaleButtonStyle())
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 20)
                    .opacity(appeared ? 1 : 0)

                    // Cards, standing up and swipeable. The actions used to sit
                    // under every card in a long stack; now they follow the one
                    // you are looking at, which is the only one they can apply to.
                    VStack(spacing: 14) {
                        WalletCarousel(cards: vm.cards, selectedID: $carouselID)
                            .padding(.top, 18)
                        if vm.cards.count > 1 {
                            WalletPageDots(cards: vm.cards, selectedID: carouselID)
                        }
                        if let card = vm.cards.first(where: { $0.id == carouselID }) ?? vm.cards.first {
                            // Actions only. CardDetailRow used to sit here and it
                            // redrew the whole card plus its balance — the same
                            // figure the carousel shows directly above it.
                            WalletCardActions(card: card,
                                              txCount: card.transactions.count,
                                              onEdit: { editingCard = card },
                                              onDelete: { deletingCard = card })
                                .padding(.horizontal, 22)
                                .id(card.id)
                                .transition(.opacity)
                        }
                    }
                    .opacity(appeared ? 1 : 0)
                    .animation(.spring(response: 0.55, dampingFraction: 0.8), value: appeared)
                    .animation(.easeOut(duration: 0.2), value: carouselID)
                    .padding(.horizontal, 22)
                    .padding(.top, 24)

                    // Total balance per currency
                    if !vm.cards.isEmpty {
                        VStack(spacing: 0) {
                            HStack {
                                Text(loc("cards.total_balance"))
                                    .font(.system(size: 13))
                                    .foregroundStyle(AppTheme.textSecondary)
                                Spacer()
                                Image(systemName: "creditcard.fill")
                                    .font(.system(size: 18))
                                    .foregroundStyle(AppTheme.accent.opacity(0.4))
                            }
                            .padding(.bottom, balancePerCurrency.count > 1 ? 10 : 6)

                            ForEach(Array(balancePerCurrency.enumerated()), id: \.element.currency) { i, item in
                                if i > 0 {
                                    Divider()
                                        .background(AppTheme.cardMid)
                                        .padding(.vertical, 8)
                                }
                                HStack(alignment: .firstTextBaseline) {
                                    Text(item.currency)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(AppTheme.textSecondary)
                                        .frame(width: 36, alignment: .leading)
                                    Spacer()
                                    Text((item.total < 0 ? "-" : "") +
                                         CurrencyManager.shared.formatted(Swift.abs(item.total), currency: item.currency))
                                        .font(.system(size: item.total < 0 ? 18 : 20, weight: .bold))
                                        .foregroundStyle(item.total < 0 ? AppTheme.red : AppTheme.accent)
                                        .contentTransition(.numericText())
                                }
                            }
                        }
                        .padding(18)
                        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(AppTheme.accent.opacity(0.2), lineWidth: 1))
                        .padding(.horizontal, 22)
                        .padding(.top, 24)
                        .opacity(appeared ? 1 : 0)
                    }

                    Spacer(minLength: 110)
                }
            }

            // Empty state
            if vm.cards.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "creditcard")
                        .font(.system(size: 48))
                        .foregroundStyle(AppTheme.textSecondary)
                    Text(loc("cards.no_cards"))
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(loc("cards.no_cards_sub"))
                        .font(.system(size: 14))
                        .foregroundStyle(AppTheme.textSecondary)
                    Button {
                        HapticManager.shared.tap()
                        showAddCard = true
                    } label: {
                        Text(loc("cards.add_card"))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(AppTheme.bg)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 14)
                            .background(AppTheme.accent, in: Capsule())
                    }
                    .buttonStyle(ScaleButtonStyle())
                }
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.8)) { appeared = true }
        }
        .sheet(isPresented: $showAddCard) {
            CardFormSheet(vm: vm, editCard: nil)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
                .preferredColorScheme(appColorScheme())
        }
        // Deletion moved up here with the actions bar. The confirmation used to
        // live inside CardDetailRow, which no longer exists.
        .alert(String(format: loc("cards.delete_confirm"), deletingCard?.last4 ?? ""),
               isPresented: Binding(get: { deletingCard != nil },
                                    set: { if !$0 { deletingCard = nil } })) {
            Button(loc("common.cancel"), role: .cancel) { deletingCard = nil }
            Button(loc("cards.delete_all"), role: .destructive) {
                if let c = deletingCard { deleteCard(c) }
                deletingCard = nil
            }
        }
        .sheet(item: $editingCard) { card in
            CardFormSheet(vm: vm, editCard: card)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
                .preferredColorScheme(appColorScheme())
        }
        .sheet(isPresented: $showTransfer) {
            CardTransferSheet(vm: vm)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
                .preferredColorScheme(appColorScheme())
        }
        .sheet(isPresented: $showTransferPaywall) {
            PaywallView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
                .preferredColorScheme(appColorScheme())
        }
    }
}

// MARK: - Network Logo View

struct CardNetworkLogo: View {
    let network: CardNetwork

    var body: some View {
        switch network {
        case .visa:
            Text("VISA")
                .font(.system(size: 20, weight: .black, design: .default))
                .foregroundStyle(.white)
                .tracking(1)

        case .mastercard:
            HStack(spacing: -8) {
                Circle()
                    .fill(Color(hex: "#EB001B").opacity(0.9))
                    .frame(width: 24, height: 24)
                Circle()
                    .fill(Color(hex: "#FF5F00").opacity(0.9))
                    .frame(width: 24, height: 24)
            }

        case .unknown:
            Image(systemName: "creditcard")
                .font(.system(size: 18))
                .foregroundStyle(AppTheme.textSecondary)
        }
    }
}

// MARK: - Card Form Sheet (Add / Edit)

struct CardFormSheet: View {
    @Bindable var vm: AppViewModel
    let editCard: BankCard?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var holderName  = ""
    @State private var cardNumber  = ""
    @State private var displayText = ""
    @State private var expireMonth = ""
    @State private var expireYear  = ""
    @State private var cardCurrency = CurrencyManager.shared.preferredCurrency
    @State private var isWallet    = false
    @State private var walletProvider: WalletProvider = .gopay
    @State private var phoneNumber = "+62"
    @State private var appeared    = false
    @State private var errorMsg: String? = nil
    /// Chosen bank issuer id. nil = auto (BIN detect / deterministic fallback).
    @State private var selectedIssuerID: String? = nil
    /// True once the user picks a bank by hand, so BIN auto-suggest stops
    /// overriding their choice as they keep typing.
    @State private var issuerTouched = false
    @FocusState private var focusedField: CardField?

    enum CardField { case number, name, month, year }

    private var isEditing: Bool { editCard != nil }
    private var detectedNetwork: CardNetwork { CardNetwork.detect(from: cardNumber) }

    /// Network dipakai untuk warna UI. Saat mode edit dengan field kosong (user
    /// tidak mengganti nomor), fallback ke network dari nomor kartu yang sudah ada
    /// agar tombol Save dan preview tidak jadi abu-abu.
    private var effectiveNetwork: CardNetwork {
        if !isWallet && isEditing && cardNumber.isEmpty, let existing = editCard {
            return CardNetwork.detect(from: existing.cardNumber)
        }
        return detectedNetwork
    }

    /// Card number used for detection — falls back to the existing number when
    /// editing without retyping.
    private var numberForDetect: String {
        (isEditing && cardNumber.isEmpty) ? (editCard?.cardNumber ?? "") : cardNumber
    }
    private var resolvedBankGradient: BankGradient {
        BankIssuer.resolveGradient(issuerID: selectedIssuerID, cardNumber: numberForDetect)
    }
    private var activeGradientStart: String {
        isWallet ? walletProvider.gradientStart : resolvedBankGradient.start
    }
    private var activeGradientEnd: String {
        isWallet ? walletProvider.gradientEnd : resolvedBankGradient.end
    }

    // MARK: - Bank Issuer Picker

    @ViewBuilder private var bankIssuerPicker: some View {
        let autoDetected = BankIssuer.detect(from: numberForDetect)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(loc("cards.issuer")).font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
                if let d = autoDetected, !issuerTouched {
                    Text(String(format: loc("cards.issuer_detected"), d.name))
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(AppTheme.accent)
                }
                Spacer()
            }
            .padding(.horizontal, 22)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    // Auto chip — clears the manual pick and re-enables detection.
                    issuerChip(title: loc("cards.issuer_auto"), start: "#3A4450", end: "#232A33",
                               selected: !issuerTouched, systemIcon: "wand.and.stars") {
                        issuerTouched = false; selectedIssuerID = autoDetected?.id
                    }
                    ForEach(BankIssuer.all) { issuer in
                        issuerChip(title: issuer.name, start: issuer.gradient.start, end: issuer.gradient.end,
                                   selected: issuerTouched && selectedIssuerID == issuer.id) {
                            issuerTouched = true; selectedIssuerID = issuer.id
                        }
                    }
                    // Neutral custom colours (manual override for any other bank).
                    ForEach(Array(BankIssuer.neutralPalette.enumerated()), id: \.offset) { i, g in
                        issuerChip(title: String(format: loc("cards.issuer_other"), i + 1),
                                   start: g.start, end: g.end,
                                   selected: issuerTouched && selectedIssuerID == "neutral-\(i)") {
                            issuerTouched = true; selectedIssuerID = "neutral-\(i)"
                        }
                    }
                }
                .padding(.horizontal, 22)
            }
        }
    }

    private func issuerChip(title: String, start: String, end: String, selected: Bool,
                            systemIcon: String? = nil, action: @escaping () -> Void) -> some View {
        Button {
            HapticManager.shared.select()
            withAnimation(.spring(response: 0.3)) { action() }
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(LinearGradient(colors: [Color(hex: start), Color(hex: end)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 54, height: 36)
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .stroke(selected ? AppTheme.accent : .clear, lineWidth: 2.5))
                    if let systemIcon {
                        Image(systemName: systemIcon).font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    if selected {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 13))
                            .foregroundStyle(.white).background(AppTheme.accent, in: Circle())
                            .offset(x: 20, y: -13)
                    }
                }
                Text(title).font(.system(size: 10, weight: selected ? .bold : .medium))
                    .foregroundStyle(selected ? AppTheme.textPrimary : AppTheme.textSecondary)
                    .lineLimit(1).frame(width: 62)
            }
        }
        .buttonStyle(ScaleButtonStyle())
    }

    private var expireDate: String {
        let m = expireMonth.prefix(2).description
        let y = expireYear.prefix(2).description
        return "\(m)/\(y)"
    }

    private var formattedCardNumber: String {
        let digits = cardNumber.replacingOccurrences(of: " ", with: "").prefix(16)
        var result = ""
        for (i, ch) in digits.enumerated() {
            if i > 0 && i % 4 == 0 { result += " " }
            result += String(ch)
        }
        return result
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 24) {

                        // ── Card type picker (only when creating) ──────────────
                        if !isEditing {
                            HStack(spacing: 0) {
                                ForEach([(false, "creditcard.fill", loc("cards.physical")),
                                         (true,  "apps.iphone",    loc("cards.wallet"))],
                                        id: \.1) { walletMode, icon, label in
                                    Button {
                                        HapticManager.shared.tap()
                                        withAnimation(.spring(response: 0.35)) {
                                            isWallet = walletMode
                                            if walletMode && phoneNumber == "" { phoneNumber = "+62" }
                                            errorMsg = nil
                                        }
                                    } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: icon)
                                                .font(.system(size: 13, weight: .semibold))
                                            Text(label)
                                                .font(.system(size: 13, weight: .semibold))
                                        }
                                        .foregroundStyle(isWallet == walletMode ? AppTheme.bg : AppTheme.textSecondary)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 11)
                                        .background(isWallet == walletMode ? AppTheme.accent : Color.clear,
                                                    in: RoundedRectangle(cornerRadius: 12))
                                    }
                                    .buttonStyle(ScaleButtonStyle())
                                }
                            }
                            .padding(4)
                            .background(AppTheme.cardMid, in: RoundedRectangle(cornerRadius: 16))
                            .padding(.horizontal, 22)
                            .padding(.top, 8)
                            .opacity(appeared ? 1 : 0)
                            .animation(.spring(response: 0.4, dampingFraction: 0.8).delay(0.02), value: appeared)
                        }

                        // ── Card preview ───────────────────────────────────────
                        CardPreviewMini(
                            holderName: holderName.isEmpty ? (isWallet ? loc("auth.name_placeholder") : loc("auth.name_placeholder")) : holderName,
                            number: isWallet ? walletProvider.rawValue : (formattedCardNumber.isEmpty ? "0000 0000 0000 0000" : formattedCardNumber),
                            expire: isWallet ? "" : (expireDate == "/" ? "MM/YY" : expireDate),
                            network: isWallet ? .unknown : effectiveNetwork,
                            gradientStart: activeGradientStart,
                            gradientEnd: activeGradientEnd,
                            isWallet: isWallet,
                            walletProvider: isWallet ? walletProvider : nil
                        )
                        .padding(.horizontal, 22)
                        .opacity(appeared ? 1 : 0)
                        .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.05), value: appeared)

                        // ── Network/wallet indicator ───────────────────────────
                        if isWallet {
                            HStack(spacing: 8) {
                                Image(systemName: "apps.iphone")
                                    .font(.system(size: 14))
                                    .foregroundStyle(walletProvider.color)
                                Text("\(walletProvider.rawValue)")
                                    .font(.system(size: 13))
                                    .foregroundStyle(walletProvider.color)
                                Spacer()
                            }
                            .padding(.horizontal, 22)
                            .opacity(appeared ? 1 : 0)
                        } else {
                            HStack(spacing: 8) {
                                CardNetworkLogo(network: effectiveNetwork)
                                Text(effectiveNetwork == .unknown
                                     ? loc("cards.networkplaceholder")
                                     : "\(effectiveNetwork.name)")
                                    .font(.system(size: 13))
                                    .foregroundStyle(effectiveNetwork == .unknown
                                                     ? AppTheme.textSecondary
                                                     : effectiveNetwork.accentColor)
                                Spacer()
                            }
                            .padding(.horizontal, 22)
                            .opacity(appeared ? 1 : 0)
                        }

                        // ── Bank issuer picker (physical cards only) ───────────
                        if !isWallet {
                            bankIssuerPicker
                                .opacity(appeared ? 1 : 0)
                        }

                        // ── Wallet provider picker (wallets only) ──────────────
                        if isWallet && !isEditing {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(loc("cards.wallet_provider"))
                                    .font(.system(size: 13))
                                    .foregroundStyle(AppTheme.textSecondary)
                                    .padding(.horizontal, 22)

                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 10) {
                                        ForEach(WalletProvider.allCases) { provider in
                                            Button {
                                                HapticManager.shared.select()
                                                withAnimation(.spring(response: 0.3)) {
                                                    walletProvider = provider
                                                }
                                            } label: {
                                                HStack(spacing: 6) {
                                                    Image(systemName: provider.icon)
                                                        .font(.system(size: 13, weight: .semibold))
                                                    Text(provider.rawValue)
                                                        .font(.system(size: 13, weight: .medium))
                                                }
                                                .foregroundStyle(walletProvider == provider ? .white : AppTheme.textSecondary)
                                                .padding(.horizontal, 14).padding(.vertical, 9)
                                                .background(walletProvider == provider
                                                    ? provider.color
                                                    : AppTheme.cardMid,
                                                    in: Capsule())
                                                .overlay(Capsule().stroke(
                                                    walletProvider == provider ? provider.color.opacity(0.5) : AppTheme.cardMid,
                                                    lineWidth: 1))
                                            }
                                            .buttonStyle(ScaleButtonStyle())
                                        }
                                    }
                                    .padding(.horizontal, 22)
                                }
                            }
                            .opacity(appeared ? 1 : 0)
                            .animation(.spring(response: 0.4, dampingFraction: 0.8).delay(0.08), value: appeared)
                            .animation(.spring(response: 0.3), value: walletProvider)
                        }

                        // ── Card number (physical card only) ───────────────────
                        if !isWallet {
                        VStack(spacing: 8) {
                            Text(loc("cards.card_number"))
                                .font(.system(size: 13))
                                .foregroundStyle(AppTheme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 22)

                            TextField(isEditing ? loc("cards.card_number_blank") : loc("cards.card_number"),
                                      text: $displayText)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(cardNumber.count == 16 ? AppTheme.accent : AppTheme.textPrimary)
                            .keyboardType(.numberPad)
                            .onChange(of: displayText) { _, newVal in
                                // Strip non-digits, hard cap at 16
                                let digits = String(newVal.filter { $0.isNumber }.prefix(16))
                                cardNumber = digits
                                // Rebuild formatted display with spaces
                                var formatted = ""
                                for (i, ch) in digits.enumerated() {
                                    if i > 0 && i % 4 == 0 { formatted += " " }
                                    formatted += String(ch)
                                }
                                // Only update displayText if it differs (avoids recursion)
                                if displayText != formatted { displayText = formatted }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
                            .padding(.horizontal, 22)

                            HStack {
                                if isEditing && cardNumber.isEmpty {
                                    HStack(spacing: 4) {
                                        Image(systemName: "info.circle.fill").font(.system(size: 10)).foregroundStyle(AppTheme.textSecondary)
                                        Text(loc("cards.leave_blank")).font(.system(size: 10)).foregroundStyle(AppTheme.textSecondary)
                                    }
                                } else {
                                    Text(String(format: loc("cards.digit_count"), cardNumber.count))
                                        .font(.system(size: 11))
                                        .foregroundStyle(cardNumber.count == 16 ? AppTheme.accent : AppTheme.textSecondary)
                                }
                                Spacer()
                                if cardNumber.count == 16 {
                                    Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(AppTheme.accent)
                                }
                            }
                            .padding(.horizontal, 22)
                        }
                        .opacity(appeared ? 1 : 0)
                        .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.1), value: appeared)
                        } // end if !isWallet (card number)

                        // Holder/account name
                        SheetField(label: isWallet ? loc("cards.wallet_holder") : loc("cards.card_holder"),
                                   placeholder: isWallet ? loc("cards.wallet_holder") : loc("cards.card_holder"),
                                   text: $holderName)
                        .opacity(appeared ? 1 : 0)
                        .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.14), value: appeared)

                        // Phone number (digital wallet only)
                        if isWallet {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(loc("cards.phone_number"))
                                    .font(.system(size: 13))
                                    .foregroundStyle(AppTheme.textSecondary)
                                    .padding(.horizontal, 22)
                                HStack(spacing: 10) {
                                    Image(systemName: "phone.fill")
                                        .font(.system(size: 14))
                                        .foregroundStyle(walletProvider.color)
                                    TextField("812 3456 7890", text: $phoneNumber)
                                        .font(.system(size: 15))
                                        .foregroundStyle(AppTheme.textPrimary)
                                        .keyboardType(.phonePad)
                                        .onChange(of: phoneNumber) { _, v in
                                            var val = v
                                            // Strip disallowed chars
                                            val = val.filter { $0.isNumber || $0 == "+" || $0 == " " || $0 == "-" }
                                            // Auto-convert 08xx → +628xx
                                            if val.hasPrefix("08") {
                                                val = "+628" + val.dropFirst(2)
                                            } else if val.hasPrefix("8") && !val.hasPrefix("+") {
                                                val = "+62" + val
                                            }
                                            // Ensure +62 prefix is never removed
                                            if !val.hasPrefix("+62") { val = "+62" }
                                            if val != v { phoneNumber = val }
                                        }
                                }
                                .padding(14)
                                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
                                .overlay(RoundedRectangle(cornerRadius: 14)
                                    .stroke(AppTheme.cardMid.opacity(0.5), lineWidth: 1))
                                .padding(.horizontal, 22)

                                // Live digit counter — local digits (excluding +62 country code)
                                let localDigits = max(phoneNumber.filter({ $0.isNumber }).count - 2, 0)
                                HStack(spacing: 6) {
                                    Image(systemName: localDigits >= 9 && localDigits <= 13 ? "checkmark.circle.fill" : "info.circle")
                                        .font(.system(size: 11))
                                        .foregroundStyle(localDigits >= 9 && localDigits <= 13 ? AppTheme.accent : localDigits > 13 ? AppTheme.red : AppTheme.textSecondary)
                                    Text(localDigits == 0
                                         ? "(+62 812 3456 7890)"
                                         : localDigits < 9
                                            ? String(format: loc("cards.phone_need_more"), localDigits, 9 - localDigits)
                                            : localDigits > 13
                                            ? loc("cards.phone_too_long")
                                            : String(format: loc("cards.phone_valid"), localDigits))
                                        .font(.system(size: 11))
                                        .foregroundStyle(localDigits > 13 ? AppTheme.red : localDigits >= 9 ? AppTheme.accent : AppTheme.textSecondary)
                                    Spacer()
                                }
                                .padding(.horizontal, 22)
                            }
                            .opacity(appeared ? 1 : 0)
                            .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.16), value: appeared)
                        }

                        // Expiry (physical card only)
                        if !isWallet {
                        VStack(spacing: 8) {
                            Text(loc("cards.expiry_date"))
                                .font(.system(size: 13))
                                .foregroundStyle(AppTheme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 22)
                            HStack(spacing: 12) {
                                TextField("MM", text: $expireMonth)
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(AppTheme.textPrimary)
                                    .keyboardType(.numberPad)
                                    .focused($focusedField, equals: .month)
                                    .multilineTextAlignment(.center)
                                    .padding(.vertical, 14)
                                    .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
                                    .frame(maxWidth: .infinity)
                                    .onChange(of: expireMonth) { _, v in
                                        var clean = v.filter { $0.isNumber }
                                        if clean.count > 2 { clean = String(clean.prefix(2)) }
                                        // Cap at 12
                                        if let m = Int(clean), m > 12 { clean = "12" }
                                        // Digits 2-9: impossible to be start of two-digit month → pad immediately
                                        if clean.count == 1, let m = Int(clean), m >= 2 { clean = "0\(m)" }
                                        expireMonth = clean
                                        // Auto-jump to year when 2 digits entered
                                        if clean.count == 2 { focusedField = .year }
                                    }
                                    // When focus leaves month field, pad single "1" → "01"
                                    .onChange(of: focusedField) { _, newField in
                                        if newField != .month && expireMonth.count == 1 {
                                            if let m = Int(expireMonth) {
                                                expireMonth = String(format: "%02d", m)
                                            }
                                        }
                                    }

                                Text("/")
                                    .font(.system(size: 20, weight: .light))
                                    .foregroundStyle(AppTheme.textSecondary)

                                TextField("YY", text: $expireYear)
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(AppTheme.textPrimary)
                                    .keyboardType(.numberPad)
                                    .focused($focusedField, equals: .year)
                                    .multilineTextAlignment(.center)
                                    .padding(.vertical, 14)
                                    .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
                                    .frame(maxWidth: .infinity)
                                    .onChange(of: expireYear) { _, v in
                                        var clean = v.filter { $0.isNumber }
                                        if clean.count > 2 { clean = String(clean.prefix(2)) }
                                        expireYear = clean
                                        if clean.count == 2 { focusedField = nil }
                                    }
                            }
                            .padding(.horizontal, 22)
                        }
                        .opacity(appeared ? 1 : 0)
                        .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.18), value: appeared)
                        } // end if !isWallet (expiry)

                        // Currency — shown for both wallet and physical, editable only when creating
                        if !isEditing {
                            VStack(alignment: .leading, spacing: 8) {
                                Menu {
                                    ForEach(CurrencyManager.supportedCurrencies, id: \.code) { c in
                                        Button {
                                            HapticManager.shared.select()
                                            cardCurrency = c.code
                                        } label: {
                                            Label("\(c.flag) \(c.code) — \(c.name)",
                                                  systemImage: cardCurrency == c.code ? "checkmark" : "")
                                        }
                                    }
                                } label: {
                                    HStack(spacing: 10) {
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 10)
                                                .fill(AppTheme.green.opacity(0.12))
                                                .frame(width: 38, height: 38)
                                            Image(systemName: "dollarsign.circle.fill")
                                                .font(.system(size: 18))
                                                .foregroundStyle(AppTheme.green)
                                        }
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(loc("common.currency"))
                                                .font(.system(size: 14, weight: .medium))
                                                .foregroundStyle(AppTheme.textPrimary)
                                        }
                                        Spacer()
                                        HStack(spacing: 6) {
                                            Text(CurrencyManager.flag(for: cardCurrency))
                                                .font(.system(size: 16))
                                            Text(cardCurrency)
                                                .font(.system(size: 14, weight: .bold))
                                                .foregroundStyle(AppTheme.accent)
                                            Image(systemName: "chevron.up.chevron.down")
                                                .font(.system(size: 10))
                                                .foregroundStyle(AppTheme.textSecondary)
                                        }
                                        .padding(.horizontal, 12).padding(.vertical, 8)
                                        .background(AppTheme.cardMid, in: RoundedRectangle(cornerRadius: 10))
                                    }
                                    .padding(14)
                                    .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 16))
                                    .overlay(RoundedRectangle(cornerRadius: 16)
                                        .stroke(AppTheme.cardMid.opacity(0.5), lineWidth: 1))
                                    .padding(.horizontal, 22)
                                }
                                .buttonStyle(ScaleButtonStyle())
                            }
                            .opacity(appeared ? 1 : 0)
                            .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.2), value: appeared)
                        } else {
                            // Locked currency display when editing
                            HStack(spacing: 10) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(AppTheme.textSecondary.opacity(0.08))
                                        .frame(width: 38, height: 38)
                                    Image(systemName: "lock.fill")
                                        .font(.system(size: 16))
                                        .foregroundStyle(AppTheme.textSecondary)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(loc("common.currency"))
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(AppTheme.textSecondary)
                                    Text(loc("cards.cannot_change"))
                                        .font(.system(size: 12))
                                        .foregroundStyle(AppTheme.textSecondary.opacity(0.6))
                                }
                                Spacer()
                                HStack(spacing: 6) {
                                    Text(CurrencyManager.flag(for: cardCurrency)).font(.system(size: 16))
                                    Text(cardCurrency).font(.system(size: 14, weight: .bold))
                                        .foregroundStyle(AppTheme.textSecondary)
                                }
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(AppTheme.cardMid.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                            }
                            .padding(14)
                            .background(AppTheme.cardDark.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
                            .overlay(RoundedRectangle(cornerRadius: 16)
                                .stroke(AppTheme.cardMid.opacity(0.3), lineWidth: 1))
                            .padding(.horizontal, 22)
                            .opacity(appeared ? 1 : 0)
                        }

                        if let err = errorMsg {
                            InlineBanner(tone: .error, message: err)
                                .padding(.horizontal, 22)
                        }

                        // Save
                        Button { save() } label: {
                            Text(isEditing ? loc("general.edit") : (isWallet ? loc("cards.add_wallet") : loc("cards.add_card")))
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(isWallet ? walletProvider.color : effectiveNetwork.accentColor,
                                            in: Capsule())
                                .shadow(color: (isWallet ? walletProvider.color : effectiveNetwork.accentColor).opacity(0.35), radius: 12, y: 6)
                        }
                        .buttonStyle(ScaleButtonStyle())
                        .padding(.horizontal, 22)
                        .opacity(appeared ? 1 : 0)
                        .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.22), value: appeared)

                        Spacer(minLength: 40)
                    }
                }
            }
            .navigationTitle(isEditing ? loc("cards.edit") : loc("cards.new_card"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc("common.cancel")) { HapticManager.shared.tap(); dismiss() }
                        .foregroundStyle(AppTheme.textSecondary)
                }

            }
        }
        .onAppear {
            if let card = editCard {
                holderName   = card.holderName
                cardNumber   = ""
                displayText  = ""
                let parts    = card.expireDate.split(separator: "/")
                expireMonth  = parts.first.map(String.init) ?? ""
                expireYear   = parts.last.map(String.init)  ?? ""
                cardCurrency = card.currency.isEmpty ? CurrencyManager.shared.preferredCurrency : card.currency
                isWallet     = card.isDigitalWallet
                if let wp = WalletProvider(rawValue: card.walletProvider) {
                    walletProvider = wp
                }
                phoneNumber = card.phoneNumber
                if !card.issuerID.isEmpty {
                    selectedIssuerID = card.issuerID
                    issuerTouched = true
                }
            }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.1)) { appeared = true }
        }
        .onChange(of: displayText) { _, _ in
            // Auto-suggest the issuer from the BIN as the user types — but never
            // clobber a bank they've already picked by hand.
            guard !issuerTouched, !isWallet else { return }
            selectedIssuerID = BankIssuer.detect(from: cardNumber)?.id
        }
    }

    private func save() {
        let name = holderName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { errorMsg = isWallet ? loc("cards.error_cardholer_blank") : loc("cards.error_cardholer_blank"); return }

        if isWallet {
            let phone = phoneNumber.trimmingCharacters(in: .whitespaces)
            guard phone != "+62" && phone.count > 3 else { errorMsg = loc("cards.error_phone"); return }
            let digitsOnly = phone.filter { $0.isNumber }
            // +62 adds "62" = 2 digits, so local number needs 9-13 more digits
            guard digitsOnly.count >= 10 && digitsOnly.count <= 15 else {
                errorMsg = loc("cards.error_phone_digits")
                return
            }
        }

        if isWallet {
            // ── Digital wallet — no card number or expiry needed ──────────
            if let card = editCard {
                card.holderName    = name
                card.gradientStart = walletProvider.gradientStart
                card.gradientEnd   = walletProvider.gradientEnd
                card.walletProvider = walletProvider.rawValue
                card.phoneNumber   = phoneNumber.trimmingCharacters(in: .whitespaces)
            } else {
                let newCard = BankCard(
                    holderName: name,
                    cardNumber: walletProvider.rawValue, // store provider as identifier
                    balance: 0.0,
                    expireDate: "Digital",
                    gradientStart: walletProvider.gradientStart,
                    gradientEnd: walletProvider.gradientEnd,
                    sortOrder: vm.cards.count,
                    currency: cardCurrency,
                    isDigitalWallet: true,
                    walletProvider: walletProvider.rawValue,
                    phoneNumber: phoneNumber.trimmingCharacters(in: .whitespaces)
                )
                modelContext.insert(newCard)
            }
        } else {
            // ── Physical card — full validation ───────────────────────────
            let rawNum = cardNumber.trimmingCharacters(in: .whitespaces)
            let finalNum: String
            if isEditing && rawNum.isEmpty {
                finalNum = editCard?.cardNumber ?? ""
            } else {
                finalNum = formattedCardNumber.trimmingCharacters(in: .whitespaces)
            }
            let num = finalNum
            let numDigits = num.replacingOccurrences(of: " ", with: "").count
            guard numDigits == 16 else { errorMsg = loc("cards.error_digits"); return }
            guard !expireMonth.isEmpty && !expireYear.isEmpty else { errorMsg = loc("cards.error_expired_blank"); return }
            guard let monthInt = Int(expireMonth), monthInt >= 1 && monthInt <= 12 else { errorMsg = loc("cards.error_expired_month"); return }
            guard let yearInt = Int(expireYear), yearInt > 0 else { errorMsg = loc("cards.error_expired_year"); return }
            let cal = Calendar.current
            let currentYear  = cal.component(.year, from: Date()) % 100
            let currentMonth = cal.component(.month, from: Date())
            if yearInt < currentYear || (yearInt == currentYear && monthInt < currentMonth) {
                errorMsg = loc("cards.error_expired"); return
            }
            // Persist the resolved issuer + its brand gradient. `selectedIssuerID`
            // is the manual pick, the BIN auto-suggest, or nil (→ deterministic
            // fallback stored as the concrete gradient below).
            let issuerID = issuerTouched ? (selectedIssuerID ?? "") : (BankIssuer.detect(from: num)?.id ?? "")
            let grad = BankIssuer.resolveGradient(issuerID: selectedIssuerID, cardNumber: num)
            if let card = editCard {
                card.holderName    = name
                card.cardNumber    = num
                card.expireDate    = expireDate
                card.issuerID      = issuerID
                card.gradientStart = grad.start
                card.gradientEnd   = grad.end
            } else {
                let newCard = BankCard(
                    holderName: name,
                    cardNumber: num,
                    balance: 0.0,
                    expireDate: expireDate,
                    gradientStart: grad.start,
                    gradientEnd: grad.end,
                    sortOrder: vm.cards.count,
                    currency: cardCurrency,
                    isDigitalWallet: false,
                    walletProvider: ""
                )
                newCard.issuerID = issuerID
                modelContext.insert(newCard)
            }
        }

        try? modelContext.save()
        HapticManager.shared.success()
        dismiss()
    }
}

// MARK: - Card Preview Mini (live in form)

struct CardPreviewMini: View {
    let holderName: String
    let number: String
    let expire: String
    let network: CardNetwork
    var gradientStart: String? = nil
    var gradientEnd: String? = nil
    var isWallet: Bool = false
    var walletProvider: WalletProvider? = nil

    private var gStart: String { gradientStart ?? network.gradientStart }
    private var gEnd: String { gradientEnd ?? network.gradientEnd }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 20)
                .fill(LinearGradient(
                    colors: [Color(hex: gStart), Color(hex: gEnd)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))

            GeometryReader { g in
                Path { p in
                    p.move(to: .init(x: g.size.width * 0.32, y: 0))
                    p.addCurve(
                        to: .init(x: g.size.width, y: g.size.height * 0.7),
                        control1: .init(x: g.size.width * 0.74, y: -12),
                        control2: .init(x: g.size.width + 8, y: g.size.height * 0.32)
                    )
                    p.addLine(to: .init(x: g.size.width, y: 0))
                    p.closeSubpath()
                }
                .fill(LinearGradient(
                    colors: [Color.white.opacity(0.12), Color.white.opacity(0.02)],
                    startPoint: .top, endPoint: .bottom
                ))
            }
            .clipShape(RoundedRectangle(cornerRadius: 20))

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    if isWallet, let wp = walletProvider {
                        // Wallet: show provider icon + "Digital Wallet" label
                        HStack(spacing: 6) {
                            Image(systemName: wp.icon)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.9))
                            Text(loc("cards.wallet"))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.7))
                        }
                    } else {
                        Image(systemName: "wave.3.right")
                            .font(.system(size: 16))
                            .foregroundStyle(Color.white.opacity(0.6))
                    }
                    Spacer()
                    if !isWallet {
                        CardNetworkLogo(network: network)
                    }
                }
                Spacer()
                if isWallet {
                    // For wallets show provider name as the "number"
                    Text(walletProvider?.rawValue ?? number)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Color.white)
                } else {
                    Text(number)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .tracking(1)
                }
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(holderName)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.white)
                    }
                    Spacer()
                    if !isWallet {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(loc("cards.expires")).font(.system(size: 9)).foregroundStyle(Color.white.opacity(0.6))
                            Text(expire).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.white)
                        }
                    }
                }
                .padding(.top, 8)
            }
            .padding(18)
        }
        .frame(height: 160)
        .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isWallet)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: walletProvider?.rawValue)
    }
}

// MARK: - Card Transfer Sheet (Royal-only)
//
// Moves money between the user's own cards/wallets. Implemented as a paired
// .transfer-subtype transaction (debit on source, credit on destination) so it
// flows through the same balance math as everything else and is correctly
// excluded from spend/save analysis. Validates that the source can't go
// negative; cross-currency transfers convert at the live rate.
struct CardTransferSheet: View {
    @Bindable var vm: AppViewModel
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var sourceIndex = 0
    @State private var destIndex   = 1
    @State private var amountText  = ""
    enum TransferEnd { case source, destination }
    @State private var picking: TransferEnd? = nil

    private var cards: [BankCard] { vm.cards }
    private var sourceCard: BankCard? { cards.indices.contains(sourceIndex) ? cards[sourceIndex] : nil }
    private var destCard:   BankCard? { cards.indices.contains(destIndex)   ? cards[destIndex]   : nil }

    /// Amount is entered in the SOURCE card's currency.
    private var amount: Double { Double(amountText.replacingOccurrences(of: ",", with: ".")) ?? 0 }
    private var sourceBalance: Double { sourceCard?.computedBalance() ?? 0 }
    private var convertedToDest: Double {
        guard let s = sourceCard, let d = destCard else { return 0 }
        return CurrencyManager.shared.convert(amount, from: s.resolvedCurrency, to: d.resolvedCurrency)
    }
    private var sameCard: Bool { sourceIndex == destIndex }
    /// The core rule: a transfer must never push the source balance negative.
    private var insufficient: Bool { amount > sourceBalance + 0.0001 }
    private var canTransfer: Bool {
        !sameCard && amount > 0 && !insufficient && sourceCard != nil && destCard != nil
    }
    private var crossCurrency: Bool {
        (sourceCard?.resolvedCurrency ?? "") != (destCard?.resolvedCurrency ?? "")
    }

    private func label(_ card: BankCard) -> String {
        if card.isDigitalWallet, !card.walletProvider.isEmpty { return card.walletProvider }
        let l4 = card.last4
        return l4.isEmpty ? (card.holderName.isEmpty ? loc("transfer.card") : card.holderName) : "•••• \(l4)"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 18) {
                        // From → To on ONE row, using the same standing cards
                        // the wallet now uses. The old layout stacked two full
                        // carousels with the amount below both, so choosing a
                        // pair and typing a figure never fit on one screen.
                        HStack(alignment: .center, spacing: 10) {
                            transferSlot(title: loc("transfer.from"),
                                         card: sourceCard) { picking = .source }
                            Button {
                                HapticManager.shared.tap()
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                                    let t = sourceIndex; sourceIndex = destIndex; destIndex = t
                                }
                            } label: {
                                Image(systemName: "arrow.left.arrow.right")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(AppTheme.accent)
                                    .frame(width: 38, height: 38)
                                    .background(AppTheme.accent.opacity(0.12), in: Circle())
                            }
                            .buttonStyle(ScaleButtonStyle())
                            transferSlot(title: loc("transfer.to"),
                                         card: destCard) { picking = .destination }
                        }
                        .padding(.horizontal, 18)

                        amountField

                        if let err = validationError {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 13))
                                Text(err).font(.system(size: 13, weight: .medium))
                            }
                            .foregroundStyle(AppTheme.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 22)
                            .transition(.opacity)
                        }
                        transferButton
                        Spacer(minLength: 30)
                    }
                    .padding(.top, 8)
                }
            }
            .navigationTitle(loc("transfer.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc("common.cancel")) { dismiss() }.foregroundStyle(AppTheme.textSecondary)
                }
            }
            .animation(.spring(response: 0.3), value: sourceIndex)
            .animation(.spring(response: 0.3), value: destIndex)
            .sheet(isPresented: Binding(get: { picking != nil },
                                        set: { if !$0 { picking = nil } })) {
                pickerSheet
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(AppTheme.bg)
                    .preferredColorScheme(appColorScheme())
            }
        }
    }

    /// One end of the transfer, drawn as a small standing card so the pair
    /// reads as "this one → that one" at a glance.
    private func transferSlot(title: String, card: BankCard?, tap: @escaping () -> Void) -> some View {
        Button {
            HapticManager.shared.tap(); tap()
        } label: {
            VStack(spacing: 8) {
                Text(title.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(AppTheme.textSecondary)
                    .tracking(0.7)
                if let card {
                    WalletCard(card: card, width: 96, compact: true)
                        .frame(width: 96)
                    Text(CurrencyManager.shared.formatted(card.computedBalance(),
                                                          currency: card.resolvedCurrency))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                } else {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(AppTheme.cardDark)
                        .frame(width: 96, height: 96 / WalletCard.aspect)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    /// Card chooser for whichever end was tapped.
    private var pickerSheet: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 10) {
                        ForEach(Array(cards.enumerated()), id: \.element.id) { i, card in
                            Button {
                                HapticManager.shared.tap()
                                if picking == .source { sourceIndex = i } else { destIndex = i }
                                picking = nil
                            } label: {
                                // A slim spine in the card's own colour, not a
                                // shrunken card face. At row height a card face
                                // is a coloured blob that crowds the name and
                                // says nothing the colour alone doesn't; the
                                // spine identifies it and leaves the row calm.
                                let chosen = (picking == .source ? sourceIndex : destIndex) == i
                                HStack(spacing: 12) {
                                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                                        .fill(LinearGradient(colors: [Color(hex: card.gradientStart),
                                                                      Color(hex: card.gradientEnd)],
                                                             startPoint: .top, endPoint: .bottom))
                                        .frame(width: 5, height: 34)
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 6) {
                                            Text(card.holderName.isEmpty ? loc("wallet.untitled") : card.holderName)
                                                .font(.system(size: 14, weight: .semibold))
                                                .foregroundStyle(AppTheme.textPrimary).lineLimit(1)
                                            if card.isDigitalWallet {
                                                Text(card.walletProvider.isEmpty
                                                     ? loc("wallet.ewallet") : card.walletProvider)
                                                    .font(.system(size: 9, weight: .semibold))
                                                    .foregroundStyle(AppTheme.textSecondary)
                                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                                    .background(AppTheme.cardMid, in: Capsule())
                                            } else if !card.last4.isEmpty {
                                                Text("·· \(card.last4)")
                                                    .font(.system(size: 11, design: .monospaced))
                                                    .foregroundStyle(AppTheme.textSecondary)
                                            }
                                        }
                                        Text(CurrencyManager.shared.formatted(card.computedBalance(),
                                                                              currency: card.resolvedCurrency))
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(AppTheme.textSecondary)
                                    }
                                    Spacer(minLength: 6)
                                    if chosen {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 19)).foregroundStyle(AppTheme.accent)
                                    }
                                }
                                .padding(.horizontal, 13).padding(.vertical, 11)
                                .background(chosen ? AppTheme.accent.opacity(0.08) : AppTheme.cardDark,
                                            in: RoundedRectangle(cornerRadius: 14))
                                .overlay(RoundedRectangle(cornerRadius: 14)
                                    .stroke(chosen ? AppTheme.accent.opacity(0.45) : Color.clear, lineWidth: 1.5))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 22).padding(.top, 12)
                }
            }
            .navigationTitle(loc(picking == .source ? "transfer.from" : "transfer.to"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
        }
    }

    private var validationError: String? {
        if sameCard { return loc("transfer.same_card") }
        if amount > 0 && insufficient { return loc("transfer.insufficient") }
        return nil
    }

    private var header: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().fill(AppTheme.accent.opacity(0.12)).frame(width: 56, height: 56)
                Image(systemName: "arrow.left.arrow.right").font(.system(size: 24)).foregroundStyle(AppTheme.accent)
            }
            Text(loc("transfer.subtitle")).font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center).padding(.horizontal, 32)
        }
        .padding(.bottom, 2)
    }

    /// Compact, breathing page indicator: the active card gets an accent pill.
    private func pageDots(selected: Int) -> some View {
        HStack(spacing: 6) {
            ForEach(cards.indices, id: \.self) { i in
                Capsule()
                    .fill(i == selected ? AppTheme.accent : AppTheme.textSecondary.opacity(0.28))
                    .frame(width: i == selected ? 18 : 6, height: 6)
                    .animation(.spring(response: 0.3, dampingFraction: 0.75), value: selected)
            }
        }
    }

    private var amountField: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(loc("transfer.amount")).font(.system(size: 12, weight: .semibold)).foregroundStyle(AppTheme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 12) {
                Text(sourceCard?.resolvedCurrency ?? "")
                    .font(.system(size: 15, weight: .bold)).foregroundStyle(AppTheme.accent)
                    .frame(width: 58, height: 56)
                    .background(AppTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                TextField("0", text: $amountText)
                    .font(.system(size: 28, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                    .keyboardType(.decimalPad)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .frame(height: 56)
                    .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(insufficient ? AppTheme.red.opacity(0.5) : AppTheme.cardMid.opacity(0.5), lineWidth: 1))
            }
            // Quick-fill chips (percentage of the source balance).
            HStack(spacing: 8) {
                quickChip("25%", fraction: 0.25)
                quickChip("50%", fraction: 0.50)
                quickChip(loc("transfer.max"), fraction: 1.0)
            }
            if crossCurrency && amount > 0 {
                Text(String(format: loc("transfer.converted"),
                            CurrencyManager.shared.formatted(convertedToDest, currency: destCard?.resolvedCurrency ?? "")))
                    .font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 4)
    }

    private func quickChip(_ title: String, fraction: Double) -> some View {
        Button {
            HapticManager.shared.tap()
            let value = sourceBalance * fraction
            let noDecimals: Set<String> = ["IDR", "JPY", "KRW", "VND"]
            let cur = (sourceCard?.resolvedCurrency ?? "").uppercased()
            amountText = noDecimals.contains(cur)
                ? String(Int(value.rounded()))
                : String(format: "%.2f", value)
        } label: {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppTheme.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(AppTheme.accent.opacity(0.10), in: Capsule())
        }
        .buttonStyle(ScaleButtonStyle())
        .disabled(sourceBalance <= 0)
    }

    private var transferButton: some View {
        Button {
            performTransfer()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.left.arrow.right").font(.system(size: 16, weight: .semibold))
                Text(loc("transfer.button")).font(.system(size: 16, weight: .bold))
            }
            .foregroundStyle(canTransfer ? AppTheme.bg : AppTheme.textSecondary)
            .frame(maxWidth: .infinity).padding(.vertical, 17)
            .background(canTransfer ? AppTheme.accent : AppTheme.cardMid, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(ScaleButtonStyle())
        .disabled(!canTransfer)
        .padding(.horizontal, 22).padding(.top, 6)
    }

    private func performTransfer() {
        guard let s = sourceCard, let d = destCard, canTransfer else { return }
        let outAmt = amount               // source currency
        let inAmt  = convertedToDest      // destination currency

        let debit = TxRecord(
            name: String(format: loc("transfer.to_name"), label(d)),
            date: Date(), amount: -outAmt, type: "tx.type.purchase",
            icon: "⇄", iconBgHex: "#38BDF8", category: .other,
            currency: s.resolvedCurrency, notes: "", subtype: .transfer)
        let credit = TxRecord(
            name: String(format: loc("transfer.from_name"), label(s)),
            date: Date(), amount: inAmt, type: "tx.type.income",
            icon: "⇄", iconBgHex: "#38BDF8", category: .other,
            currency: d.resolvedCurrency, notes: "", subtype: .transfer)

        s.transactions.append(debit)
        d.transactions.append(credit)
        try? context.save()
        HapticManager.shared.success()
        dismiss()
    }
}

// MARK: - Transfer Card Tile
//
// Purpose-built gradient tile for the transfer carousel: shows the card's
// identity + its available balance front-and-center (the number that matters
// when moving money). Reuses the same gradient/network styling as the real
// card previews so the deck feels like flipping through your own wallet.
private struct TransferCardTile: View {
    let card: BankCard
    let title: String
    let highlightInsufficient: Bool
    let inUse: Bool

    private var network: CardNetwork { CardNetwork.detect(from: card.cardNumber) }
    private var gStart: String { card.gradientStart.isEmpty ? network.gradientStart : card.gradientStart }
    private var gEnd:   String { card.gradientEnd.isEmpty   ? network.gradientEnd   : card.gradientEnd }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 22)
                .fill(LinearGradient(
                    colors: [Color(hex: gStart), Color(hex: gEnd)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))

            // Soft gloss sweep.
            GeometryReader { g in
                Path { p in
                    p.move(to: .init(x: g.size.width * 0.32, y: 0))
                    p.addCurve(
                        to: .init(x: g.size.width, y: g.size.height * 0.7),
                        control1: .init(x: g.size.width * 0.74, y: -12),
                        control2: .init(x: g.size.width + 8, y: g.size.height * 0.32))
                    p.addLine(to: .init(x: g.size.width, y: 0))
                    p.closeSubpath()
                }
                .fill(LinearGradient(
                    colors: [Color.white.opacity(0.12), Color.white.opacity(0.02)],
                    startPoint: .top, endPoint: .bottom))
            }
            .clipShape(RoundedRectangle(cornerRadius: 22))

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    HStack(spacing: 7) {
                        Image(systemName: card.isDigitalWallet ? "wallet.pass.fill" : "wave.3.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.75))
                        Text(title)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    Spacer()
                    if card.isCreditCard {
                        Text(loc("cc.badge"))
                            .font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.white.opacity(0.22), in: Capsule())
                    } else if inUse {
                        Text(loc("transfer.in_use"))
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(Color.white.opacity(0.20), in: Capsule())
                    } else if !card.isDigitalWallet {
                        CardNetworkLogo(network: network)
                    }
                }
                Spacer()
                // A credit card shows what's OWED + available (paying it reduces
                // owed), not a cash balance.
                Text((card.isCreditCard ? loc("cc.owed") : loc("transfer.available_label")).uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(.white.opacity(0.7))
                Text(card.isCreditCard ? card.formattedOwed : card.formattedBalance)
                    .font(.system(size: 26, weight: .heavy))
                    .foregroundStyle(highlightInsufficient ? Color(hex: "#FFD1D1") : .white)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                if card.isCreditCard {
                    Text(String(format: loc("cc.avail_short"), card.formattedAvailable))
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                }
            }
            .padding(18)
        }
        .frame(height: 150)
        .shadow(color: .black.opacity(0.28), radius: 14, y: 7)
    }
}
