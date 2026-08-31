// AIChatView.swift
// DiPo AI Advisor — a credit-metered chatbot that turns natural-language
// sentences ("beli telur gulung 5rb dan es kelapa 5rb tunai") into
// transaction confirmation cards the user can add with one tap.
//
// Backend: Cloudflare Worker /api/chat — same per-user credit ledger as
// the receipt scanner (1 credit per message). The worker returns parsed
// transactions; this view renders them and writes confirmed ones into
// SwiftData.

import SwiftUI
import SwiftData

// MARK: - Models

/// One parsed transaction proposed by the AI, awaiting user confirmation.
struct AIParsedTx: Identifiable {
    let id = UUID()
    let name: String
    let amount: Double          // always positive
    let isExpense: Bool
    let category: TxCategory
    let currency: String
    let date: Date
    let notes: String
    var added: Bool = false     // flipped true once written to SwiftData
}

/// A single chat bubble. Assistant messages may carry parsed transactions.
struct AIChatMessage: Identifiable {
    let id = UUID()
    enum Role { case user, assistant }
    let role: Role
    var text: String
    var transactions: [AIParsedTx]
    var isError: Bool

    init(role: Role, text: String, transactions: [AIParsedTx] = [], isError: Bool = false) {
        self.role = role
        self.text = text
        self.transactions = transactions
        self.isError = isError
    }
}

// MARK: - View Model

@MainActor
@Observable
final class AIChatViewModel {
    var messages: [AIChatMessage] = []
    var input: String = ""
    var isLoading = false
    /// Remaining monthly AI credits. nil until first load.
    var creditsLeft: Int? = nil

    private let chatURL    = "https://dipo-receipt-scanner.fahmi-aquinas.workers.dev/api/chat"
    private let creditsURL = "https://dipo-receipt-scanner.fahmi-aquinas.workers.dev/api/credits"

    // ── Worker payload / response shapes ──────────────────────────────────

    private struct ChatRequest: Encodable {
        let userId: String
        let userPlan: String
        let message: String
        let currencyHint: String
        /// Compact snapshot of the user's in-app finances (income, expenses,
        /// categories, budget, debts, goals) so the assistant can ANALYZE and
        /// give data-driven insights — not just log transactions. Built fresh
        /// per message by the view from SwiftData.
        let context: String
        /// The app's language, so the assistant's reply follows what the user
        /// is reading — not the language they happened to type in. Without it
        /// the model inferred, and two English messages in a row could get one
        /// English reply and one Indonesian.
        let language: String
    }
    private struct ChatResponse: Decodable {
        let reply: String
        let transactions: [WireTx]
        let creditsLeft: Int?
    }
    private struct WireTx: Decodable {
        let name: String
        let amount: Double
        let type: String           // "expense" | "income"
        let category: String
        let currency: String
        let dateISO: String?
        let notes: String?
    }
    private struct CreditsRequest: Encodable {
        let userId: String
        let userPlan: String
    }
    private struct CreditsResponse: Decodable {
        let balance: Int
    }

    // ── Credit balance ────────────────────────────────────────────────────

    func loadCredits() async {
        guard let userId = UserSession.shared.userID else { return }
        let body = try? JSONEncoder().encode(
            CreditsRequest(userId: userId, userPlan: PremiumManager.shared.plan.rawValue))
        guard let body else { return }
        let endpoint = Endpoint(path: creditsURL, method: .post,
                                headers: ["X-DiPo-Client": "iOS"], body: body)
        if let resp: CreditsResponse = try? await NetworkService.shared.fetch(endpoint) {
            creditsLeft = resp.balance
        }
    }

    // ── Send a message ────────────────────────────────────────────────────

    func send(context: String = "") async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isLoading else { return }
        guard let userId = UserSession.shared.userID else { return }

        messages.append(AIChatMessage(role: .user, text: text))
        input = ""

        // Try locally first. Plain entries like "beli kopi 25rb dan parkir 5rb"
        // are a tokenising problem, and sending them to a language model costs a
        // credit, a round trip, and a working connection for no added judgement.
        // The parser returns nil unless it is confident, so anything ambiguous
        // still reaches the model.
        if let local = LocalTxParser.parse(text) {
            let parsed = local.items.map { item in
                AIParsedTx(name: item.name, amount: item.amount,
                           isExpense: item.isExpense, category: item.category,
                           currency: CurrencyManager.shared.preferredCurrency,
                           date: .now, notes: "tx.note.quick_entry")
            }
            messages.append(AIChatMessage(role: .assistant,
                text: loc(parsed.count == 1 ? "ai.local_one" : "ai.local_many"),
                transactions: parsed))
            return
        }

        isLoading = true
        defer { isLoading = false }

        let payload = ChatRequest(
            userId: userId,
            userPlan: PremiumManager.shared.plan.rawValue,
            message: text,
            currencyHint: CurrencyManager.shared.preferredCurrency,
            context: context,
            language: LanguageManager.shared.current.rawValue
        )
        guard let body = try? JSONEncoder().encode(payload) else {
            messages.append(AIChatMessage(role: .assistant,
                text: loc("ai.error.generic"), isError: true))
            return
        }
        let endpoint = Endpoint(path: chatURL, method: .post,
                                headers: ["X-DiPo-Client": "iOS"], body: body)
        do {
            let resp: ChatResponse = try await NetworkService.shared.fetch(endpoint)
            if let left = resp.creditsLeft { creditsLeft = left }
            let parsed = resp.transactions.filter { abs($0.amount) > 0 }.map { wire -> AIParsedTx in
                AIParsedTx(
                    name: wire.name,
                    amount: abs(wire.amount),
                    isExpense: wire.type != "income",
                    category: TxCategory(rawValue: wire.category) ?? .other,
                    currency: wire.currency,
                    date: Self.parseDate(wire.dateISO),
                    notes: wire.notes ?? ""
                )
            }
            messages.append(AIChatMessage(role: .assistant,
                text: resp.reply, transactions: parsed))
        } catch let netError as NetworkError {
            // 402 = out of monthly AI credits.
            if case .httpError(let code) = netError, code == 402 {
                creditsLeft = 0
                messages.append(AIChatMessage(role: .assistant,
                    text: loc("ai.error.out_of_credits"), isError: true))
            } else {
                // Always log the technical detail to the console (visible
                // in Xcode), but the USER only ever sees a friendly message.
                // The HTTP code is appended in DEBUG builds only — so
                // TestFlight / App Store users never see "HTTP 404".
                print("[AskDiPo] chat failed: \(netError)")
                messages.append(AIChatMessage(role: .assistant,
                    text: Self.userErrorText(for: netError), isError: true))
            }
        } catch {
            print("[AskDiPo] chat failed: \(error)")
            messages.append(AIChatMessage(role: .assistant,
                text: loc("ai.error.generic"), isError: true))
        }
    }

    /// User-facing error text. Release builds always show the friendly,
    /// generic message — no scary HTTP codes. DEBUG builds append the
    /// status so developers can diagnose on-device during testing.
    private static func userErrorText(for error: NetworkError) -> String {
        let base = loc("ai.error.generic")
        #if DEBUG
        if case .httpError(let code) = error { return base + " (HTTP \(code))" }
        return base + " (network)"
        #else
        return base
        #endif
    }

    /// "2026-05-19" → Date, fallback today.
    private static func parseDate(_ iso: String?) -> Date {
        guard let iso else { return .now }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: iso) ?? .now
    }
}

// MARK: - Chat View

struct AIChatView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \BankCard.sortOrder) private var cards: [BankCard]
    /// Needed so a credit card's available credit accounts for principal that
    /// running instalments still hold.
    @Query private var installments: [CardInstallment]
    @Query private var debts: [DebtRecord]
    @Query private var goals: [SavingsGoal]
    @Query private var recurrings: [RecurringExpense]
    @Query private var cycleIntents: [CycleIntent]

    @State private var vm = AIChatViewModel()
    @State private var selectedCardID: UUID? = nil
    @FocusState private var inputFocused: Bool

    /// Set by the Back Tap / Siri shortcut so the sheet opens already listening.
    var autoStartVoice: Bool = false

    @State private var voice = VoiceDictation()
    @State private var voiceNotice: String? = nil
    @State private var showCardPicker = false

    /// Card new transactions are written to. Defaults to the first card.
    private var targetCard: BankCard? {
        if let id = selectedCardID { return cards.first { $0.id == id } }
        return cards.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(AppTheme.cardMid)
            if cards.isEmpty {
                noCardState
            } else {
                cardPickerBar
                Divider().overlay(AppTheme.cardMid)
                chatScroll
                inputBar
            }
        }
        .background(AppTheme.bg)
        .task {
            await vm.loadCredits()
            if selectedCardID == nil { selectedCardID = cards.first?.id }
            // Friendly opening message.
            if vm.messages.isEmpty {
                vm.messages.append(AIChatMessage(role: .assistant,
                    text: loc("ai.greeting")))
            }
            // Arriving from Back Tap / Siri: start listening immediately. The
            // whole point of the gesture is that nothing else needs pressing.
            // Speaking IS the submit. Waiting for a second tap defeats the
            // point of the gesture — and nothing is written to the ledger yet:
            // the reply comes back as a card the user still has to add, so a
            // misheard sentence costs a glance, not a wrong transaction.
            voice.onFinish = { text in
                guard !text.isEmpty else { return }
                vm.input = text
                inputFocused = false
                let snapshot = buildFinancialContext()
                Task { await vm.send(context: snapshot) }
            }
            if autoStartVoice {
                await voice.start()
            }
        }
        // Live transcript flows straight into the field so the user watches
        // their words land and can fix them by hand before sending.
        .onChange(of: voice.transcript) { _, text in
            guard !text.isEmpty else { return }
            vm.input = text
        }
        .onChange(of: voice.state) { _, newState in
            switch newState {
            case .denied(let why):      voiceNotice = why
            case .unavailable(let why): voiceNotice = why
            case .idle, .listening:     break
            }
        }
        .onDisappear { voice.cancel() }
        .sheet(isPresented: $showCardPicker) {
            cardPickerSheet
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
                .preferredColorScheme(appColorScheme())
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppTheme.purple)
                Text(loc("ai.title"))
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
            }
            Spacer()
            // Credit counter chip — shown ONLY when credits are running
            // low (< 10). A paying user with a healthy balance never sees
            // a depleting counter, so the feature feels unlimited; the
            // chip surfaces just in time as a gentle "almost out" warning.
            if let credits = vm.creditsLeft, credits < 10 {
                HStack(spacing: 5) {
                    Image(systemName: "bolt.fill").font(.system(size: 10))
                    Text("\(credits)")
                        .font(.system(size: 13, weight: .bold))
                        .contentTransition(.numericText())
                }
                .foregroundStyle(credits == 0 ? AppTheme.red : AppTheme.orange)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background((credits == 0 ? AppTheme.red : AppTheme.orange).opacity(0.12),
                            in: Capsule())
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: Card picker

    /// Short, human-readable label for a card — "Holder ·· 1234".
    /// A credit card has no "balance" in the cash sense. Running
    /// `computedBalance()` on one applies the cash formula (seed + transactions)
    /// to a liability account and prints a meaningless figure — which is how a
    /// credit card came to advertise "Rp 1jt" that was neither a balance nor a
    /// limit. What matters when choosing a credit card as the destination is
    /// how much room is left on it.
    private func subtitle(for card: BankCard) -> String {
        let cm = CurrencyManager.shared
        if card.isCreditCard {
            return String(format: loc("cc.available_short"),
                          cm.formatted(card.availableCredit(installments),
                                       currency: card.resolvedCurrency))
        }
        return cm.formatted(card.computedBalance(), currency: card.resolvedCurrency)
    }

    private func cardLabel(_ card: BankCard) -> String {
        let last4 = String(card.cardNumber.filter(\.isNumber).suffix(4))
        let name  = card.isDigitalWallet && !card.walletProvider.isEmpty
            ? card.walletProvider
            : card.holderName
        if name.isEmpty { return last4.isEmpty ? loc("ai.add_to") : "•• \(last4)" }
        return last4.isEmpty ? name : "\(name) ·· \(last4)"
    }

    /// Lets the user choose which card AI-confirmed transactions land in.
    /// Defaults to the first card; shown as a tappable menu so it stays
    /// compact even with many cards.
    private var cardPickerBar: some View {
        Button {
            guard cards.count > 1 else { return }
            HapticManager.shared.tap()
            showCardPicker = true
        } label: {
            HStack(spacing: 9) {
                // The card's own colour, so the destination is recognisable at a
                // glance rather than by reading four digits.
                RoundedRectangle(cornerRadius: 4)
                    .fill(targetCard.map { LinearGradient(colors: [Color(hex: $0.gradientStart),
                                                                   Color(hex: $0.gradientEnd)],
                                                          startPoint: .topLeading,
                                                          endPoint: .bottomTrailing) }
                          ?? LinearGradient(colors: [AppTheme.cardMid, AppTheme.cardMid],
                                            startPoint: .top, endPoint: .bottom))
                    .frame(width: 26, height: 17)
                Text(loc("ai.add_to"))
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.textSecondary)
                Text(targetCard.map(cardLabel) ?? "—")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                if cards.count > 1 {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(cards.count <= 1)
    }

    /// Card chooser. The system Menu showed a bare list of names with no way to
    /// tell an e-wallet from a bank account or to see what is in either.
    private var cardPickerSheet: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 10) {
                        ForEach(cards) { card in
                            Button {
                                HapticManager.shared.tap()
                                selectedCardID = card.id
                                showCardPicker = false
                            } label: {
                                HStack(spacing: 12) {
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(LinearGradient(colors: [Color(hex: card.gradientStart),
                                                                      Color(hex: card.gradientEnd)],
                                                             startPoint: .topLeading,
                                                             endPoint: .bottomTrailing))
                                        .frame(width: 42, height: 28)
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 5) {
                                            Text(cardLabel(card))
                                                .font(.system(size: 14, weight: .semibold))
                                                .foregroundStyle(AppTheme.textPrimary)
                                                .lineLimit(1)
                                            if card.isCreditCard {
                                                Text(loc("cc.badge"))
                                                    .font(.system(size: 8, weight: .bold))
                                                    .foregroundStyle(AppTheme.purple)
                                                    .padding(.horizontal, 4).padding(.vertical, 1)
                                                    .background(AppTheme.purple.opacity(0.15), in: Capsule())
                                            }
                                        }
                                        Text(subtitle(for: card))
                                            .font(.system(size: 11))
                                            .foregroundStyle(AppTheme.textSecondary)
                                    }
                                    Spacer(minLength: 8)
                                    if selectedCardID == card.id {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 18))
                                            .foregroundStyle(AppTheme.accent)
                                    }
                                }
                                .padding(12)
                                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
                                .overlay(RoundedRectangle(cornerRadius: 14)
                                    .stroke(selectedCardID == card.id
                                            ? AppTheme.accent.opacity(0.5) : Color.clear, lineWidth: 1.5))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 22).padding(.top, 12)
                }
            }
            .navigationTitle(loc("ai.add_to"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
        }
    }

    // MARK: Chat scroll

    private var chatScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(vm.messages) { msg in
                        messageRow(msg).id(msg.id)
                    }
                    if vm.isLoading {
                        HStack {
                            ProgressView().scaleEffect(0.8)
                            Text(loc("ai.thinking"))
                                .font(.system(size: 13))
                                .foregroundStyle(AppTheme.textSecondary)
                            Spacer()
                        }
                        .padding(.horizontal, 18)
                        .id("loading")
                    }
                }
                .padding(.vertical, 16)
            }
            .onChange(of: vm.messages.count) { _, _ in
                withAnimation { proxy.scrollTo(vm.messages.last?.id, anchor: .bottom) }
            }
            .onChange(of: vm.isLoading) { _, loading in
                if loading { withAnimation { proxy.scrollTo("loading", anchor: .bottom) } }
            }
        }
    }

    @ViewBuilder
    private func messageRow(_ msg: AIChatMessage) -> some View {
        if msg.role == .user {
            HStack {
                Spacer(minLength: 50)
                Text(msg.text)
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(AppTheme.accent, in: RoundedRectangle(cornerRadius: 16))
            }
            .padding(.horizontal, 18)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text(msg.text)
                    .font(.system(size: 14))
                    .foregroundStyle(msg.isError ? AppTheme.red : AppTheme.textPrimary)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 16))
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(msg.transactions) { tx in
                    txCard(tx, in: msg.id)
                }
            }
            .padding(.horizontal, 18)
        }
    }

    // MARK: Transaction confirmation card

    @ViewBuilder
    private func txCard(_ tx: AIParsedTx, in messageID: UUID) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(tx.category.color.opacity(0.18))
                        .frame(width: 38, height: 38)
                    Image(systemName: tx.category.icon)
                        .font(.system(size: 15))
                        .foregroundStyle(tx.category.color)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(tx.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(tx.category.displayLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                Spacer()
                Text((tx.isExpense ? "-" : "+") +
                     CurrencyManager.shared.formatted(tx.amount, currency: tx.currency))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(tx.isExpense ? AppTheme.red : AppTheme.accent)
            }
            // Add / Added button.
            Button {
                addTransaction(tx, in: messageID)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: tx.added ? "checkmark.circle.fill" : "plus.circle.fill")
                    Text(tx.added ? loc("ai.tx.added") : loc("ai.tx.add"))
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tx.added ? AppTheme.accent : .white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(tx.added ? AppTheme.accent.opacity(0.12) : AppTheme.accent,
                            in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(tx.added)
        }
        .padding(12)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(AppTheme.cardMid, lineWidth: 1))
    }

    // MARK: Input bar

    /// Mic toggle. While listening it turns into a stop button with a live
    /// level ring, so the user can see the mic is hearing them — a static icon
    /// gives no way to tell "still listening" from "already died".
    private var micButton: some View {
        Button {
            HapticManager.shared.tap()
            voiceNotice = nil
            if voice.isListening {
                voice.stop()
            } else {
                voice.reset()
                inputFocused = false
                Task { await voice.start() }
            }
        } label: {
            ZStack {
                Circle()
                    .fill(voice.isListening ? AppTheme.red.opacity(0.15) : AppTheme.cardDark)
                    .frame(width: 38, height: 38)
                if voice.isListening {
                    Circle()
                        .stroke(AppTheme.red.opacity(0.55), lineWidth: 2)
                        .frame(width: 38, height: 38)
                        .scaleEffect(1 + voice.level * 0.35)
                        .animation(.easeOut(duration: 0.12), value: voice.level)
                }
                Image(systemName: voice.isListening ? "stop.fill" : "mic.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(voice.isListening ? AppTheme.red : AppTheme.textSecondary)
            }
        }
        .buttonStyle(.plain)
        .disabled(vm.isLoading)
        .opacity(vm.isLoading ? 0.5 : 1)
        .accessibilityLabel(loc(voice.isListening ? "voice.stop" : "voice.start"))
    }

    private var inputBar: some View {
        VStack(spacing: 0) {
            Divider().overlay(AppTheme.cardMid)
            // Permission refusals and "no recogniser for this language" have to
            // be said out loud. A mic button that silently does nothing is the
            // most common way voice input reads as broken.
            if let voiceNotice {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 11)).foregroundStyle(AppTheme.orange)
                    Text(voiceNotice)
                        .font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.top, 8)
            }

            HStack(spacing: 10) {
                micButton

                TextField(voice.isListening ? loc("voice.listening") : loc("ai.input_placeholder"),
                          text: $vm.input, axis: .vertical)
                    .font(.system(size: 14))
                    .lineLimit(1...4)
                    .focused($inputFocused)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 18))
                Button {
                    inputFocused = false
                    let snapshot = buildFinancialContext()
                    Task { await vm.send(context: snapshot) }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(AppTheme.accent, in: Circle())
                }
                .disabled(vm.input.trimmingCharacters(in: .whitespaces).isEmpty || vm.isLoading)
                .opacity(vm.input.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            // 1 credit/message hint.
            Text(loc("ai.credit_hint"))
                .font(.system(size: 10))
                .foregroundStyle(AppTheme.textSecondary.opacity(0.7))
                .padding(.bottom, 8)
        }
        .background(AppTheme.bg)
    }

    private var noCardState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "creditcard")
                .font(.system(size: 40))
                .foregroundStyle(AppTheme.textSecondary)
            Text(loc("ai.no_card"))
                .font(.system(size: 14))
                .foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Add transaction to SwiftData

    private func addTransaction(_ tx: AIParsedTx, in messageID: UUID) {
        guard let card = targetCard else { return }
        HapticManager.shared.success()
        let record = TxRecord(
            name: tx.name,
            date: tx.date,
            amount: tx.isExpense ? -tx.amount : tx.amount,
            type: tx.isExpense ? "tx.type.purchase" : "tx.type.income",
            icon: String(tx.name.prefix(2)).uppercased(),
            iconBgHex: tx.category.iconBg,
            category: tx.category,
            currency: tx.currency,
            notes: tx.notes
        )
        card.transactions.append(record)
        try? context.save()

        // Mark the card as added in the message list.
        if let mi = vm.messages.firstIndex(where: { $0.id == messageID }),
           let ti = vm.messages[mi].transactions.firstIndex(where: { $0.id == tx.id }) {
            vm.messages[mi].transactions[ti].added = true
        }
    }

    // MARK: - Financial snapshot for analysis

    /// Builds a compact, plain-text snapshot of the user's current finances so
    /// the assistant can answer "how am I doing", "where did my money go",
    /// "am I overspending", etc. with REAL numbers instead of generic advice.
    /// Everything is converted to the preferred currency and capped in length
    /// to keep the prompt cheap. Sent fresh with every message.
    private func buildFinancialContext() -> String {
        let cm = CurrencyManager.shared
        let pref = cm.preferredCurrency
        let cal = Calendar.current
        let monthStart = cal.safeDate(from: cal.dateComponents([.year, .month], from: Date()))
        let allTx = cards.flatMap { $0.transactions }
        // Transfers between own cards aren't income/expense — exclude from sums.
        let monthTx = allTx.filter { $0.date >= monthStart && $0.txSubtype != .transfer }

        func toPref(_ amount: Double, _ cur: String) -> Double {
            cm.convert(amount, from: cur.isEmpty ? pref : cur, to: pref)
        }

        let income   = monthTx.filter { $0.amount > 0 }.reduce(0.0) { $0 + toPref($1.amount, $1.currency) }
        let expenses = monthTx.filter { $0.amount < 0 }.reduce(0.0) { $0 + toPref(abs($1.amount), $1.currency) }
        let net = income - expenses
        let savingsRate = income > 0 ? Int((net / income) * 100) : 0

        // Expense breakdown by category (preferred currency), biggest first.
        var byCat: [TxCategory: Double] = [:]
        for tx in monthTx where tx.amount < 0 {
            byCat[tx.category, default: 0] += toPref(abs(tx.amount), tx.currency)
        }
        let topCats = byCat.sorted { $0.value > $1.value }.prefix(6)
            .map { "\($0.key.rawValue) \(cm.formatted($0.value, currency: pref))" }
            .joined(separator: ", ")

        // A few most-recent transactions for concrete reference.
        let recent = allTx.sorted { $0.date > $1.date }.prefix(8).map { tx -> String in
            let sign = tx.amount < 0 ? "-" : "+"
            return "\(sign)\(cm.formatted(abs(tx.amount), currency: tx.currency)) \(tx.name) [\(tx.category.rawValue)]"
        }.joined(separator: "; ")

        let monthName = Date().formatted(.dateTime.month(.wide).year())
        var lines: [String] = [
            "Currency: \(pref). Month: \(monthName).",
            "Income this month: \(cm.formatted(income, currency: pref)).",
            "Expenses this month: \(cm.formatted(expenses, currency: pref)).",
            "Net saved: \(cm.formatted(net, currency: pref)) (savings rate \(savingsRate)%).",
            "Transactions this month: \(monthTx.count).",
        ]
        if !topCats.isEmpty { lines.append("Top expense categories: \(topCats).") }
        if !recent.isEmpty  { lines.append("Recent transactions: \(recent).") }

        let sb = SmartBudgetManager.shared
        if sb.hasActiveBudget {
            lines.append("Budget plan: Daily \(Int(sb.dailyRatio*100))% / Lifestyle \(Int(sb.lifestyleRatio*100))% / Invest-Debt \(Int(sb.investDebtRatio*100))% of income.")
        }

        // Recurring plan + duplicate suspicion. Without this the assistant
        // treats a manual twin of an auto-recorded charge (same amount, often
        // a different name) as extra "variable living costs" — the plan lets
        // it separate fixed commitments, and the warning tells it to verify
        // instead of double-counting.
        let activeRecurrings = recurrings.filter { $0.isActive }
        if !activeRecurrings.isEmpty {
            let r = activeRecurrings.prefix(6).map {
                "\($0.label) \(cm.formatted(toPref($0.amount, $0.currency), currency: pref)) (day \($0.dayOfMonth))"
            }.joined(separator: "; ")
            lines.append("Recurring plan (fixed commitments): \(r).")
            let recentExpense = allTx.filter {
                $0.amount < 0 && $0.txSubtype == .normal
                    && $0.date >= Date().addingTimeInterval(-31 * 86_400)
            }
            let dupes = sb.detectRecurringDuplicates(
                expenseTx: recentExpense, recurrings: activeRecurrings,
                expectedPerPlan: 1, currency: pref)
            for s in dupes {
                lines.append("Possible duplicate: '\(s.label)' shows \(s.found) similar-amount charges (\(cm.formatted(s.chargeAmount, currency: pref)) each) in the last 31 days but the plan expects \(s.expected) — a manual entry may twin the auto-recorded one. Verify before counting both as variable living costs.")
            }
        }

        let activeDebts = debts.filter { $0.isActive }
        if !activeDebts.isEmpty {
            let d = activeDebts.prefix(5).map {
                "\($0.name): owe \(cm.formatted($0.currentBalance, currency: $0.currency)) at \(String(format: "%.1f", $0.annualInterestRate))% APR"
            }.joined(separator: "; ")
            lines.append("Active debts: \(d).")
        }

        let activeGoals = goals.filter { !$0.isCompleted }
        if !activeGoals.isEmpty {
            let g = activeGoals.prefix(5).map {
                "\($0.name) \(Int($0.progressPercent))% (\(cm.formatted($0.savedAmount, currency: $0.currency)) of \(cm.formatted($0.targetAmount, currency: $0.currency)))"
            }.joined(separator: "; ")
            lines.append("Savings goals: \(g).")
        }

        // Deliberate choices the user declared. The assistant must report the
        // consequences but must not treat them as mistakes to correct.
        let activeIntents = cycleIntents.filter { $0.kind != nil }
        if !activeIntents.isEmpty {
            let described = activeIntents.compactMap { row -> String? in
                guard let kind = row.kind else { return nil }
                return row.note.isEmpty ? kind.label : "\(kind.label) (\"\(row.note)\")"
            }.joined(separator: "; ")
            lines.append("Deliberate choices the user declared for recent cycles: \(described). Treat these as intentional: state consequences plainly, but do NOT advise reversing them or frame them as mistakes unless the user asks.")
        }

        var ctx = lines.joined(separator: "\n")
        // Cap sized so the recurring-plan and duplicate-warning lines never
        // push debts/goals off the end (they truncate last).
        if ctx.count > 2600 { ctx = String(ctx.prefix(2600)) }
        return ctx
    }
}
