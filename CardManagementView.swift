import SwiftUI
import SwiftData


// MARK: - Card Type Detection

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
    @Environment(\.modelContext) private var context
    @State private var showAddCard    = false
    @State private var editingCard: BankCard? = nil
    @State private var appeared       = false

    private func formattedTotalAllCards(_ cards: [BankCard]) -> String {
        let total = cards.reduce(0.0) { $0 + $1.balance + $1.transactions.reduce(0) { $0 + $1.amount } }
        let currency = cards.flatMap { $0.transactions }.first?.currency ?? CurrencyManager.shared.preferredCurrency
        return CurrencyManager.shared.formatted(Swift.abs(total), currency: currency)
    }

    var body: some View {
        ZStack {
            AppTheme.bg.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    // Header
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("My Cards")
                                .font(.system(size: 24, weight: .bold))
                                .foregroundStyle(AppTheme.textPrimary)
                            Text("\(vm.cards.count) card\(vm.cards.count == 1 ? "" : "s")")
                                .font(.system(size: 13))
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                        Spacer()
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
                    .padding(.horizontal, 22)
                    .padding(.top, 20)
                    .opacity(appeared ? 1 : 0)

                    // Cards
                    VStack(spacing: 20) {
                        ForEach(Array(vm.cards.enumerated()), id: \.element.id) { i, card in
                            CardDetailRow(
                                card: card,
                                vm: vm,
                                context: context,
                                onEdit: { editingCard = card }
                            )
                            .opacity(appeared ? 1 : 0)
                            .offset(y: appeared ? 0 : 24)
                            .animation(.spring(response: 0.55, dampingFraction: 0.8).delay(Double(i) * 0.08), value: appeared)
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 24)

                    // Total balance
                    if !vm.cards.isEmpty {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Total balance")
                                    .font(.system(size: 13))
                                    .foregroundStyle(AppTheme.textSecondary)
                                Text(formattedTotalAllCards(vm.cards))
                                    .font(.system(size: 22, weight: .bold))
                                    .foregroundStyle(AppTheme.accent)
                                    .contentTransition(.numericText())
                            }
                            Spacer()
                            Image(systemName: "creditcard.fill")
                                .font(.system(size: 24))
                                .foregroundStyle(AppTheme.accent.opacity(0.4))
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
                    Text("No cards yet")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text("Add your first card to get started")
                        .font(.system(size: 14))
                        .foregroundStyle(AppTheme.textSecondary)
                    Button {
                        HapticManager.shared.tap()
                        showAddCard = true
                    } label: {
                        Text("Add Card")
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
        }
        .sheet(item: $editingCard) { card in
            CardFormSheet(vm: vm, editCard: card)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
        }
    }
}

// MARK: - Card Detail Row

struct CardDetailRow: View {
    let card: BankCard
    @Bindable var vm: AppViewModel
    let context: ModelContext
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
        if txCount > 0 { parts.append("\(txCount) transaction\(txCount == 1 ? "" : "s")") }
        if !linkedSchedules.isEmpty {
            let names = linkedSchedules.map { $0.label }.joined(separator: ", ")
            parts.append("\(linkedSchedules.count) salary schedule\(linkedSchedules.count == 1 ? "" : "s") (\(names))")
        }
        if parts.isEmpty { return "No linked data. Safe to delete." }
        return "Permanently deletes: " + parts.joined(separator: " + ")
    }

    private var network: CardNetwork { CardNetwork.detect(from: card.cardNumber) }
    private var liveBalance: Double { card.transactions.reduce(0) { $0 + $1.amount } }
    private var totalBalance: Double { card.balance + liveBalance }
    private var formattedTotalBalance: String {
        let currency = card.transactions.first?.currency ?? CurrencyManager.shared.preferredCurrency
        return (totalBalance < 0 ? "-" : "") + CurrencyManager.shared.formatted(Swift.abs(totalBalance), currency: currency)
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
                        colors: [network.accentColor.opacity(0.3), network.accentColor.opacity(0.05)],
                        startPoint: .top, endPoint: .bottom
                    ))
                }
                .clipShape(RoundedRectangle(cornerRadius: 20))

                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Image(systemName: "wave.3.right")
                            .font(.system(size: 16))
                            .foregroundStyle(AppTheme.textSecondary)
                        Spacer()
                        // Network logo
                        CardNetworkLogo(network: network)
                    }
                    Spacer()
                    Text(card.holderName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(maskedNumber(card.cardNumber))
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.textSecondary)
                        .padding(.top, 2)
                    HStack(alignment: .bottom) {
                        Text(formattedTotalBalance)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(AppTheme.textPrimary)
                            .contentTransition(.numericText())
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("Expires").font(.system(size: 9)).foregroundStyle(AppTheme.textSecondary)
                            Text(card.expireDate).font(.system(size: 12, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
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
                        Circle()
                            .fill(network.accentColor)
                            .frame(width: 7, height: 7)
                        Text(network.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(AppTheme.textPrimary)
                    }
                    Text("\(card.transactions.count) transaction\(card.transactions.count == 1 ? "" : "s")")
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
        .confirmationDialog("Delete ••••\(card.cardNumber.suffix(4))?",
                            isPresented: $showDeleteConfirm,
                            titleVisibility: .visible) {
            Button("Delete Card & All Linked Data", role: .destructive) { deleteCard() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteSummary)
        }
    }

    // PCI DSS compliance: Never display full card number
    private func maskedNumber(_ number: String) -> String {
        let digits = number.replacingOccurrences(of: " ", with: "")
        guard digits.count >= 4 else { return "•••• •••• •••• ••••" }
        return "•••• •••• •••• " + digits.suffix(4)
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
    var context: ModelContext? = nil   // kept for compatibility, but ignored
    let editCard: BankCard?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext   // always use this

    @State private var holderName  = ""
    @State private var cardNumber  = ""   // raw digits only, max 16
    @State private var displayText = ""   // formatted display "XXXX XXXX XXXX XXXX"
    @State private var expireMonth = ""
    @State private var expireYear  = ""
    @State private var appeared    = false
    @State private var errorMsg: String? = nil
    @FocusState private var focusedField: CardField?

    enum CardField { case number, name, month, year }

    private var isEditing: Bool { editCard != nil }
    private var detectedNetwork: CardNetwork { CardNetwork.detect(from: cardNumber) }

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

                        // Live card preview
                        CardPreviewMini(
                            holderName: holderName.isEmpty ? "Your Name" : holderName,
                            number: formattedCardNumber.isEmpty ? "0000 0000 0000 0000" : formattedCardNumber,
                            expire: expireDate == "/" ? "MM/YY" : expireDate,
                            network: detectedNetwork
                        )
                        .padding(.horizontal, 22)
                        .padding(.top, 8)
                        .opacity(appeared ? 1 : 0)
                        .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.05), value: appeared)

                        // Network indicator
                        HStack(spacing: 8) {
                            CardNetworkLogo(network: detectedNetwork)
                            Text(detectedNetwork == .unknown
                                 ? "Enter card number to detect network"
                                 : "\(detectedNetwork.name) detected")
                                .font(.system(size: 13))
                                .foregroundStyle(detectedNetwork == .unknown
                                                 ? AppTheme.textSecondary
                                                 : detectedNetwork.accentColor)
                            Spacer()
                        }
                        .padding(.horizontal, 22)
                        .opacity(appeared ? 1 : 0)

                        // Card number (PCI DSS: only last 4 shown when editing)
                        VStack(spacing: 8) {
                            HStack {
                                Text("Card number")
                                    .font(.system(size: 13))
                                    .foregroundStyle(AppTheme.textSecondary)
                                Spacer()
                                HStack(spacing: 4) {
                                    Image(systemName: "lock.shield.fill")
                                        .font(.system(size: 10))
                                        .foregroundStyle(AppTheme.accent.opacity(0.7))
                                    Text("PCI DSS secured")
                                        .font(.system(size: 10))
                                        .foregroundStyle(AppTheme.accent.opacity(0.7))
                                }
                            }
                            .padding(.horizontal, 22)

                            TextField(isEditing ? "Enter new number (or leave blank)" : "Card number",
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
                                        Text("Leave blank to keep existing number").font(.system(size: 10)).foregroundStyle(AppTheme.textSecondary)
                                    }
                                } else {
                                    Text("\(cardNumber.count)/16 digits")
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

                        // Holder name
                        SheetField(label: "Cardholder name",
                                   placeholder: "Full name on card",
                                   text: $holderName)
                        .opacity(appeared ? 1 : 0)
                        .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.14), value: appeared)

                        // Expiry
                        VStack(spacing: 8) {
                            Text("Expiry date")
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

                        if let err = errorMsg {
                            Text(err)
                                .font(.system(size: 13))
                                .foregroundStyle(AppTheme.red)
                                .padding(.horizontal, 22)
                                .transition(.opacity)
                        }

                        // Save
                        Button { save() } label: {
                            Text(isEditing ? "Save Changes" : "Add Card")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(AppTheme.bg)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(detectedNetwork.accentColor, in: Capsule())
                                .shadow(color: detectedNetwork.accentColor.opacity(0.35), radius: 12, y: 6)
                        }
                        .buttonStyle(ScaleButtonStyle())
                        .padding(.horizontal, 22)
                        .opacity(appeared ? 1 : 0)
                        .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.22), value: appeared)

                        Spacer(minLength: 40)
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Card" : "New Card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { HapticManager.shared.tap(); dismiss() }
                        .foregroundStyle(AppTheme.textSecondary)
                }

            }
        }
        .onAppear {
            if let card = editCard {
                holderName  = card.holderName
                // PCI DSS: Don't pre-fill full card number when editing
                cardNumber  = ""
                displayText = ""
                let parts   = card.expireDate.split(separator: "/")
                expireMonth = parts.first.map(String.init) ?? ""
                expireYear  = parts.last.map(String.init)  ?? ""
            }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.1)) { appeared = true }
        }
    }

    private func save() {
        let name = holderName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { errorMsg = "Enter cardholder name"; return }

        // PCI DSS: when editing, allow keeping existing number
        let rawNum = cardNumber.trimmingCharacters(in: .whitespaces)
        let finalNum: String
        if isEditing && rawNum.isEmpty {
            finalNum = editCard?.cardNumber ?? ""
        } else {
            finalNum = formattedCardNumber.trimmingCharacters(in: .whitespaces)
        }

        let num = finalNum
        let numDigits = num.replacingOccurrences(of: " ", with: "").count
        guard numDigits == 16 else {
            errorMsg = "Card number must be exactly 16 digits"; return
        }
        guard !expireMonth.isEmpty && !expireYear.isEmpty else {
            errorMsg = "Enter expiry date (MM/YY)"; return
        }
        guard let monthInt = Int(expireMonth), monthInt >= 1 && monthInt <= 12 else {
            errorMsg = "Month must be between 01 and 12"; return
        }
        guard let yearInt = Int(expireYear), yearInt > 0 else {
            errorMsg = "Enter a valid year (YY)"; return
        }
        // Check not already expired
        let cal = Calendar.current
        let currentYear  = cal.component(.year, from: Date()) % 100
        let currentMonth = cal.component(.month, from: Date())
        if yearInt < currentYear || (yearInt == currentYear && monthInt < currentMonth) {
            errorMsg = "Card has already expired"; return
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
                sortOrder: vm.cards.count
            )
            modelContext.insert(newCard)
        }

        // Just save — @Query in RootView observes the change and
        // automatically updates vm.cards throughout the whole app
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

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 20)
                .fill(LinearGradient(
                    colors: [Color(hex: network.gradientStart), Color(hex: network.gradientEnd)],
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
                    colors: [network.accentColor.opacity(0.3), network.accentColor.opacity(0.05)],
                    startPoint: .top, endPoint: .bottom
                ))
            }
            .clipShape(RoundedRectangle(cornerRadius: 20))

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Image(systemName: "wave.3.right")
                        .font(.system(size: 16))
                        .foregroundStyle(AppTheme.textSecondary)
                    Spacer()
                    CardNetworkLogo(network: network)
                }
                Spacer()
                Text(number)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .tracking(1)
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(holderName)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(AppTheme.textPrimary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Expires").font(.system(size: 9)).foregroundStyle(AppTheme.textSecondary)
                        Text(expire).font(.system(size: 12, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                    }
                }
                .padding(.top, 8)
            }
            .padding(18)
        }
        .frame(height: 160)
        .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: network.name)
    }
}
