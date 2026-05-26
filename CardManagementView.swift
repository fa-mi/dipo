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
    @State private var showAddCard    = false
    @State private var editingCard: BankCard? = nil
    @State private var appeared       = false


    /// Kelompokkan saldo per mata uang kartu. Tiap kartu dijumlah dalam currency-nya sendiri
    /// sehingga IDR tidak dicampur dengan USD — display jujur tanpa estimasi kurs.
    private var balancePerCurrency: [(currency: String, total: Double)] {
        var dict: [String: Double] = [:]
        for card in vm.cards {
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

    var body: some View {
        ZStack {
            AppTheme.bg.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    // Header
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(loc("cards.title"))
                                .font(.system(size: 24, weight: .bold))
                                .foregroundStyle(AppTheme.textPrimary)
                            Text(String(format: loc(vm.cards.count == 1 ? "cards.card_count" : "cards.card_counts"), vm.cards.count))
                                .font(.system(size: 13))
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                        Spacer()
                        HStack(spacing: 12) {
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

                    // Cards
                    VStack(spacing: 20) {
                        ForEach(Array(vm.cards.enumerated()), id: \.element.id) { i, card in
                            CardDetailRow(
                                card: card,
                                vm: vm,
                                onEdit: { editingCard = card }
                            )
                            .opacity(appeared ? 1 : 0)
                            .offset(y: appeared ? 0 : 24)
                            .animation(.spring(response: 0.55, dampingFraction: 0.8).delay(Double(i) * 0.08), value: appeared)
                        }
                    }
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
        .sheet(item: $editingCard) { card in
            CardFormSheet(vm: vm, editCard: card)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
                .preferredColorScheme(appColorScheme())
        }
    }
}

// MARK: - Card Detail Row

struct CardDetailRow: View {
    @Bindable var card: BankCard
    @Bindable var vm: AppViewModel
    let onEdit: () -> Void
    @Environment(\.modelContext) private var modelContext
    @Query private var allSchedules: [SalarySchedule]

    @State private var showActions       = false
    @State private var showDeleteConfirm = false

    private var linkedSchedules: [SalarySchedule] {
        allSchedules.filter { $0.cardID == card.id }
    }

    private var deleteSummary: String {
        var parts: [String] = []
        let txCount = card.transactions.count
        if txCount > 0 {
            parts.append(String(format: loc(txCount == 1 ? "cards.tx_count" : "cards.tx_counts"), txCount))
        }
        if !linkedSchedules.isEmpty {
            let names = linkedSchedules.map { $0.label }.joined(separator: ", ")
            let schedKey = linkedSchedules.count == 1 ? "cards.salary_count" : "cards.salary_counts"
            parts.append(String(format: loc(schedKey), linkedSchedules.count, names))
        }
        if parts.isEmpty { return loc("cards.delete_info_empty") }
        return String(format: loc("cards.delete_info_exists"), parts.joined(separator: " + "))
    }

    private var network: CardNetwork { CardNetwork.detect(from: card.cardNumber) }
    private var cardCurrency: String {
        card.currency.isEmpty ? CurrencyManager.shared.preferredCurrency : card.currency
    }
    private var liveBalance: Double {
        card.transactions.reduce(0.0) { sum, tx in
            sum + CurrencyManager.shared.convert(tx.amount, from: tx.currency, to: cardCurrency)
        }
    }
    private var totalBalance: Double { card.balance + liveBalance }
    private var formattedTotalBalance: String {
        (totalBalance < 0 ? "-" : "") + CurrencyManager.shared.formatted(Swift.abs(totalBalance), currency: cardCurrency)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Mini card preview
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 20)
                    .fill(LinearGradient(
                        colors: [Color(hex: card.gradientStart), Color(hex: card.gradientEnd)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))

                // Wave
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
                        Image(systemName: "wave.3.right")
                            .font(.system(size: 16))
                            .foregroundStyle(Color.white.opacity(0.6))
                        Spacer()
                        // Network/wallet logo
                        if card.isDigitalWallet, let wp = WalletProvider(rawValue: card.walletProvider) {
                            HStack(spacing: 4) {
                                Image(systemName: wp.icon)
                                    .font(.system(size: 13))
                                    .foregroundStyle(Color.white.opacity(0.9))
                                Text(loc("cards.wallet"))
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(Color.white.opacity(0.7))
                            }
                        } else {
                            CardNetworkLogo(network: network)
                        }
                    }
                    Spacer()
                    Text(card.holderName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.white)
                    // Phone or card number — inline eye toggle on the right
                    HStack(spacing: 6) {
                        if card.isDigitalWallet {
                            Text(card.displayPhone)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.white.opacity(0.6))
                        } else {
                            Text(card.displayNumber)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.white.opacity(0.6))
                        }
                        Spacer()
                        Button {
                            HapticManager.shared.tap()
                            card.isHidden.toggle()
                        } label: {
                            Image(systemName: card.isHidden ? "eye.slash" : "eye")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        .buttonStyle(ScaleButtonStyle())
                    }
                    .padding(.top, 2)
                    HStack(alignment: .bottom) {
                        Text(card.isHidden ? "••••••" : formattedTotalBalance)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(Color.white)
                            .contentTransition(.numericText())
                        Spacer()
                        if !card.isDigitalWallet {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(loc("cards.expires")).font(.system(size: 9)).foregroundStyle(Color.white.opacity(0.6))
                                Text(card.expireDate).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.white)
                            }
                        }
                    }
                    .padding(.top, 8)
                }
                .padding(18)
            }
            .frame(height: 160)

            // Card info + actions
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        if card.isDigitalWallet, let wp = WalletProvider(rawValue: card.walletProvider) {
                            Circle().fill(wp.color).frame(width: 7, height: 7)
                            Text(wp.rawValue)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(AppTheme.textPrimary)
                        } else {
                            Circle().fill(network.accentColor).frame(width: 7, height: 7)
                            Text(network.name)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(AppTheme.textPrimary)
                        }
                    }
                    Text(String(format: loc(card.transactions.count == 1 ? "cards.tx_count" : "cards.tx_counts"), card.transactions.count))
                        .font(.system(size: 12))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                Spacer()
                // Edit button
                Button {
                    HapticManager.shared.tap()
                    onEdit()
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 14))
                        .foregroundStyle(AppTheme.textSecondary)
                        .frame(width: 36, height: 36)
                        .background(AppTheme.cardMid, in: Circle())
                }
                .buttonStyle(ScaleButtonStyle())

                // Delete button
                Button {
                    HapticManager.shared.warning()
                    showDeleteConfirm = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 14))
                        .foregroundStyle(AppTheme.red.opacity(0.8))
                        .frame(width: 36, height: 36)
                        .background(AppTheme.red.opacity(0.1), in: Circle())
                }
                .buttonStyle(ScaleButtonStyle())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 20))
        .confirmationDialog(String(format: loc("cards.delete_confirm"), card.last4),
                            isPresented: $showDeleteConfirm,
                            titleVisibility: .visible) {
            Button(loc("cards.delete_all"), role: .destructive) { deleteCard() }
            Button(loc("common.cancel"), role: .cancel) {}
        } message: {
            Text(deleteSummary)
        }
    }

    private func deleteCard() {
        for schedule in linkedSchedules { modelContext.delete(schedule) }
        modelContext.delete(card)  // cascade deletes all TxRecords
        try? modelContext.save()
        HapticManager.shared.warning()
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

    private var activeGradientStart: String {
        isWallet ? walletProvider.gradientStart : effectiveNetwork.gradientStart
    }
    private var activeGradientEnd: String {
        isWallet ? walletProvider.gradientEnd : effectiveNetwork.gradientEnd
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
            }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.1)) { appeared = true }
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
            let network = CardNetwork.detect(from: num)
            if let card = editCard {
                card.holderName    = name
                card.cardNumber    = num
                card.expireDate    = expireDate
                card.gradientStart = network.gradientStart
                card.gradientEnd   = network.gradientEnd
            } else {
                let newCard = BankCard(
                    holderName: name,
                    cardNumber: num,
                    balance: 0.0,
                    expireDate: expireDate,
                    gradientStart: network.gradientStart,
                    gradientEnd: network.gradientEnd,
                    sortOrder: vm.cards.count,
                    currency: cardCurrency,
                    isDigitalWallet: false,
                    walletProvider: ""
                )
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
