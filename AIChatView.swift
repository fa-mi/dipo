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

    // No `userPlan` in either request: the Worker asks RevenueCat for the
    // plan itself, and wants the Firebase ID token WorkerAuth attaches.
    private struct ChatRequest: Encodable {
        let userId: String
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
    }
    private struct CreditsResponse: Decodable {
        let balance: Int
    }

    // ── Credit balance ────────────────────────────────────────────────────

    func loadCredits() async {
        guard let userId = UserSession.shared.userID else { return }
        let body = try? JSONEncoder().encode(CreditsRequest(userId: userId))
        guard let body else { return }
        let endpoint = Endpoint(path: creditsURL, method: .post,
                                headers: await WorkerAuth.headers(), body: body)
        if let resp: CreditsResponse = try? await NetworkService.shared.fetch(endpoint) {
            creditsLeft = resp.balance
        }
    }

    /// Did DiPo's last turn ask for something?
    ///
    /// A question mark is crude but it holds in both languages, and the cost of
    /// being wrong is asymmetric: a false positive spends one credit on an
    /// entry the parser could have handled, while a false negative files a
    /// transaction under the wrong name.
    ///
    /// Messages carrying transactions are excluded — those already recorded
    /// something, so whatever follows starts fresh.
    private var lastAssistantAskedSomething: Bool {
        guard let last = messages.last(where: { $0.role == .assistant }) else { return false }
        guard last.transactions.isEmpty else { return false }
        return last.text.contains("?")
    }

    // ── Send a message ────────────────────────────────────────────────────

    func send(context: String = "") async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isLoading else { return }
        guard let userId = UserSession.shared.userID else { return }

        // Read BEFORE the new message is appended, so "the last thing DiPo
        // said" is not the message we are about to answer.
        let isFollowUp = lastAssistantAskedSomething

        messages.append(AIChatMessage(role: .user, text: text))
        input = ""

        // Try locally first. Plain entries like "beli kopi 25rb dan parkir 5rb"
        // are a tokenising problem, and sending them to a language model costs a
        // credit, a round trip, and a working connection for no added judgement.
        // The parser returns nil unless it is confident, so anything ambiguous
        // still reaches the model.
        //
        // Except when the user is ANSWERING a question. The parser sees one
        // message at a time, so "Harganya 25.000" — the reply to "berapa
        // harganya?" — looked like a complete entry and was filed under the
        // name "Harganya", losing the nasi goreng it was the price of. A reply
        // only means anything alongside the question, and the model is the
        // only part of this that can see both.
        if !isFollowUp, let local = LocalTxParser.parse(text) {
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

        // The local parser couldn't take it, so it needs the model — and there
        // is no signal to reach it. Hand the text back instead of failing it.
        guard NetworkService.shared.isOnline else {
            keepForLater(text)
            return
        }

        isLoading = true
        defer { isLoading = false }

        let payload = ChatRequest(
            userId: userId,
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
                                headers: await WorkerAuth.headers(), body: body)
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
            if netError.isLostSignal {
                // Patchy coverage: the path looked up, the request never made
                // it. Same treatment as being offline from the start.
                keepForLater(text)
            } else if case .httpError(let code) = netError, code == 402 {
                // 402 = out of monthly AI credits.
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

    /// No signal, or too little to finish the request.
    ///
    /// The message used to be lost: the input box is cleared before sending,
    /// so a failure left a generic error and nothing to resend — the user had
    /// to type it again, on the patchy coverage where that happens most. Now
    /// the text goes back into the box, and DiPo says why and what still works
    /// without internet.
    ///
    /// It is NOT sent automatically when the signal returns: each model reply
    /// spends one of the user's AI credits, and they should choose to spend it
    /// — by which time what they meant to ask may have changed.
    private func keepForLater(_ text: String) {
        // The user bubble for this text was just added; the text is going
        // back to the box, so the bubble would be a duplicate on resend.
        if let last = messages.last, last.role == .user, last.text == text {
            messages.removeLast()
        }
        // Don't clobber anything typed while the request was in flight.
        if input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            input = text
        }
        messages.append(AIChatMessage(role: .assistant,
            text: loc("ai.offline.kept"), isError: true))
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
    /// A sentence already captured elsewhere — by `VoiceCaptureView` — to be
    /// sent as soon as this view appears. The voice screen deliberately does
    /// no parsing of its own; this is where the sentence lands.
    var initialMessage: String? = nil
    /// Smart Insights DiPo opens with, most urgent first. Home passes them.
    var insights: [SmartInsight] = []
    /// Free can open Ask DiPo and hear the top insight; chatting is Royal.
    var isRoyal: Bool = true
    @State private var showVoiceCapture = false
    @State private var showPaywall = false
    @State private var showGame = false

    // DiPo in 3D at the top, reacting to what he says.
    @State private var dipoMood: DiPoMood = .idle
    @State private var dipoLine = ""
    @State private var dipoTalk: Double = 0
    @State private var dipoVoice = DiPoVoice()
    /// Speak every reply aloud. Off by default; a question asked by voice is
    /// always answered by voice too.
    @AppStorage("dipo_speaks_replies") private var speakAlways = false
    @State private var askedByVoice = false
    /// DiPo's opening lines; replies after these are what he reacts to.
    @State private var openingCount = 0

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
            // Friendly opening message, then what DiPo has noticed.
            if vm.messages.isEmpty {
                vm.messages.append(AIChatMessage(role: .assistant,
                    text: loc("ai.greeting")))
                if !insights.isEmpty {
                    for line in DiPoScript.lines(unread: 0, insights: insights, isRoyal: isRoyal) {
                        let head = [line.exclamation, line.title].filter { !$0.isEmpty }.joined(separator: " ")
                        vm.messages.append(AIChatMessage(role: .assistant, text: "\(head)\n\(line.text)"))
                        dipoMood = line.mood
                    }
                }
                dipoLine = vm.messages.last.map { $0.id.uuidString } ?? ""
                openingCount = vm.messages.count
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
                submit(byVoice: true)
            }
            if let initialMessage, !initialMessage.isEmpty, vm.messages.isEmpty {
                vm.input = initialMessage
                askedByVoice = true
                let snapshot = buildFinancialContext()
                await vm.send(context: snapshot)
            } else if autoStartVoice {
                // Legacy path. New entry points open `VoiceCaptureView`, which
                // gives dictation a screen of its own instead of running it
                // inside a chat with a keyboard competing for the same space.
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
        .onDisappear { voice.cancel(); dipoVoice.stop() }
        // Each new reply: DiPo reacts, and says it aloud when asked aloud.
        .onChange(of: vm.messages.count) { _, _ in
            guard vm.messages.count > openingCount,
                  let last = vm.messages.last, last.role == .assistant else { return }
            dipoMood = last.isError ? .worry : .happy
            let spoken = askedByVoice || speakAlways
            dipoTalk = spoken ? DiPoVoice.estimatedSeconds(last.text) : 1.2
            dipoLine = last.id.uuidString
            if spoken { dipoVoice.speak(last.text) }
            askedByVoice = false
        }
        .fullScreenCover(isPresented: $showVoiceCapture) {
            VoiceCaptureView { text in
                vm.input = text
                submit(byVoice: true)
            }
            .preferredColorScheme(appColorScheme())
        }
        .fullScreenCover(isPresented: $showGame) {
            DiPoRunGameView(isRoyal: isRoyal)
                .preferredColorScheme(appColorScheme())
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView()
                .presentationDetents([.large]).presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg).preferredColorScheme(appColorScheme())
        }
        .sheet(isPresented: $showCardPicker) {
            cardPickerSheet
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
                .preferredColorScheme(appColorScheme())
        }
        .trackScreen(.askDiPo)
    }

    // MARK: Header

    /// DiPo in 3D, with the title, the speak-aloud toggle and the credit chip.
    private var header: some View {
        ZStack(alignment: .top) {
            DiPoDragonView(mood: dipoMood, line: dipoLine, talkSeconds: dipoTalk, crowned: isRoyal)
                .frame(width: 170, height: 150)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
            HStack(spacing: 10) {
                Text(loc("ai.title"))
                    .font(.system(.body, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                Spacer()
                // Credit counter chip — shown ONLY when credits are running
                // low (< 10). A paying user with a healthy balance never sees
                // a depleting counter, so the feature feels unlimited; the
                // chip surfaces just in time as a gentle "almost out" warning.
                if let credits = vm.creditsLeft, credits < 10 {
                    HStack(spacing: 5) {
                        Image(systemName: "bolt.fill").font(.system(.caption2)).imageScale(.small)
                        Text("\(credits)")
                            .font(.system(.footnote, weight: .bold))
                            .contentTransition(.numericText())
                    }
                    .foregroundStyle(credits == 0 ? AppTheme.red : AppTheme.orange)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background((credits == 0 ? AppTheme.red : AppTheme.orange).opacity(0.12),
                                in: Capsule())
                }
                Button {
                    HapticManager.shared.tap()
                    showGame = true
                } label: {
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(AppTheme.royalGoldText)
                        .frame(width: 36, height: 36)
                        .background(AppTheme.cardDark, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(loc("game.title"))
                Button {
                    HapticManager.shared.tap()
                    speakAlways.toggle()
                    if !speakAlways { dipoVoice.stop() }
                } label: {
                    Image(systemName: speakAlways ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(speakAlways ? AppTheme.accent : AppTheme.textSecondary)
                        .frame(width: 36, height: 36)
                        .background(AppTheme.cardDark, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(loc(speakAlways ? "dipo.speak_on" : "dipo.speak_off"))
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
        }
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
                    .font(.system(.caption))
                    .foregroundStyle(AppTheme.textSecondary)
                Text(targetCard.map(cardLabel) ?? "—")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                if cards.count > 1 {
                    Image(systemName: "chevron.down")
                        .font(.system(.caption2, weight: .bold)).imageScale(.small)
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
                                CardListRow(card: card,
                                            selected: selectedCardID == card.id,
                                            showsRadio: false)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 22).padding(.top, 12)
                    .containerRelativeFrame(.horizontal)
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
                                .font(.system(.footnote))
                                .foregroundStyle(AppTheme.textSecondary)
                            Spacer()
                        }
                        .padding(.horizontal, 18)
                        .id("loading")
                    }
                }
                .padding(.vertical, 16)
                .containerRelativeFrame(.horizontal)
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
                    .font(.system(.subheadline))
                    .foregroundStyle(AppTheme.onVividFill)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(AppTheme.accentFill, in: RoundedRectangle(cornerRadius: AppRadius.md))
            }
            .padding(.horizontal, 18)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                // DiPo speaks in his own bubble, like on Home.
                Text(msg.text)
                    .font(.system(.subheadline))
                    .lineSpacing(2)
                    .foregroundStyle(msg.isError ? AppTheme.red : AppTheme.textPrimary)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .dipoBubble()
                    .padding(.trailing, 30)
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
                    RoundedRectangle(cornerRadius: AppRadius.sm)
                        .fill(tx.category.color.opacity(0.18))
                        .frame(width: 38, height: 38)
                    Image(systemName: tx.category.icon)
                        .font(.system(.subheadline))
                        .foregroundStyle(tx.category.color)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(tx.name)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(tx.category.displayLabel)
                        .font(.system(.caption2))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                Spacer()
                Text((tx.isExpense ? "-" : "+") +
                     CurrencyManager.shared.formatted(tx.amount, currency: tx.currency))
                    .font(.system(.subheadline, weight: .bold))
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
                .font(.system(.footnote, weight: .semibold))
                .foregroundStyle(tx.added ? AppTheme.accent : .white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(tx.added ? AppTheme.accent.opacity(0.12) : AppTheme.accent,
                            in: RoundedRectangle(cornerRadius: AppRadius.sm))
            }
            .buttonStyle(.plain)
            .disabled(tx.added)
        }
        .padding(12)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.md).stroke(AppTheme.cardMid, lineWidth: 1))
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
                // Only reachable from the legacy auto-start path.
                voice.stop()
            } else if !isRoyal {
                showPaywall = true
            } else {
                inputFocused = false
                showVoiceCapture = true
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
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(voice.isListening ? AppTheme.red : AppTheme.textSecondary)
            }
        }
        .buttonStyle(.plain)
        .disabled(vm.isLoading)
        .opacity(vm.isLoading ? 0.5 : 1)
        .accessibilityLabel(loc(voice.isListening ? "voice.stop" : "voice.start"))
    }

    /// Questions to start with, until the user has asked something.
    @ViewBuilder
    private var suggestions: some View {
        if !vm.messages.contains(where: { $0.role == .user }) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(0..<DiPoVoice.questionCount, id: \.self) { i in
                        Button {
                            HapticManager.shared.tap()
                            vm.input = loc("dipo.q.\(i)")
                            submit(byVoice: false)
                        } label: {
                            Text(loc("dipo.q.\(i)"))
                                .font(.system(.footnote, weight: .semibold))
                                .foregroundStyle(AppTheme.accent)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .overlay(Capsule().stroke(AppTheme.accent, lineWidth: 1.5))
                        }
                        .buttonStyle(.plain)
                        .disabled(vm.isLoading)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
        }
    }

    /// Sends what is in the field. Free sees what Royal adds instead.
    private func submit(byVoice: Bool) {
        guard isRoyal else { showPaywall = true; return }
        askedByVoice = byVoice
        let snapshot = buildFinancialContext()
        Task { await vm.send(context: snapshot) }
    }

    private var inputBar: some View {
        VStack(spacing: 0) {
            Divider().overlay(AppTheme.cardMid)
            suggestions
            // Permission refusals and "no recogniser for this language" have to
            // be said out loud. A mic button that silently does nothing is the
            // most common way voice input reads as broken.
            if let voiceNotice {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(.caption2)).foregroundStyle(AppTheme.orange)
                    Text(voiceNotice)
                        .font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.top, 8)
            }

            HStack(spacing: 10) {
                micButton

                TextField(voice.isListening ? loc("voice.listening") : loc("ai.input_placeholder"),
                          text: $vm.input, axis: .vertical)
                    .font(.system(.subheadline))
                    .lineLimit(1...4)
                    .focused($inputFocused)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
                Button {
                    inputFocused = false
                    submit(byVoice: false)
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(.callout, weight: .bold))
                        .foregroundStyle(AppTheme.onVividFill)
                        .frame(width: 38, height: 38)
                        .background(AppTheme.accentFill, in: Circle())
                }
.accessibilityLabel(loc("a11y.send"))
                .disabled(vm.input.trimmingCharacters(in: .whitespaces).isEmpty || vm.isLoading)
                .opacity(vm.input.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            // 1 credit/message hint.
            Text(loc("ai.credit_hint"))
                .font(.system(.caption2))
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
                .font(.system(.subheadline))
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
            lines.append("Budget plan: Daily \(BudgetGroup.pct(sb.dailyRatio))% / Lifestyle \(BudgetGroup.pct(sb.lifestyleRatio))% / Invest-Debt \(BudgetGroup.pct(sb.investDebtRatio))% of income.")
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
            // The same check the Smart Budget screen runs: a bill DiPo recorded
            // and another entry of the same amount in the same month.
            let dupes = RecurringDuplicates.find(
                transactions: allTx, recurrings: activeRecurrings, payDay: nil, salaryDates: [],
                currency: pref, since: Date().addingTimeInterval(-31 * 86_400))
            for d in dupes {
                lines.append("Possible duplicate: '\(d.planLabel)' was recorded by DiPo and a second entry of \(cm.formatted(d.amount, currency: pref)) ('\(d.twin.name)') sits in the same month — one may be a manual twin of the other. Verify before counting both as living costs.")
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
