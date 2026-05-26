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

    func send() async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isLoading else { return }
        guard let userId = UserSession.shared.userID else { return }

        messages.append(AIChatMessage(role: .user, text: text))
        input = ""
        isLoading = true
        defer { isLoading = false }

        let payload = ChatRequest(
            userId: userId,
            userPlan: PremiumManager.shared.plan.rawValue,
            message: text,
            currencyHint: CurrencyManager.shared.preferredCurrency
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
            let parsed = resp.transactions.map { wire -> AIParsedTx in
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

    @State private var vm = AIChatViewModel()
    @State private var selectedCardID: UUID? = nil
    @FocusState private var inputFocused: Bool

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
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
            }
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
        Menu {
            ForEach(cards) { card in
                Button {
                    selectedCardID = card.id
                    HapticManager.shared.tap()
                } label: {
                    if selectedCardID == card.id {
                        Label(cardLabel(card), systemImage: "checkmark")
                    } else {
                        Text(cardLabel(card))
                    }
                }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "creditcard.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.accent)
                Text(loc("ai.add_to"))
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.textSecondary)
                Text(targetCard.map(cardLabel) ?? "—")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(AppTheme.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
        .disabled(cards.count <= 1)
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

    private var inputBar: some View {
        VStack(spacing: 0) {
            Divider().overlay(AppTheme.cardMid)
            HStack(spacing: 10) {
                TextField(loc("ai.input_placeholder"), text: $vm.input, axis: .vertical)
                    .font(.system(size: 14))
                    .lineLimit(1...4)
                    .focused($inputFocused)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 18))
                Button {
                    inputFocused = false
                    Task { await vm.send() }
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
}
