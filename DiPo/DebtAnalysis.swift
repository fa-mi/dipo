import SwiftUI
import SwiftData

// MARK: - Debt analysis by DiPo AI
//
// The Debts screen answers with rules: a verdict, a payoff order, Smart
// Budget's one piece of advice. Rules are exact, instant and free, but they
// can't weigh one thing against another — a short month against a loan that
// may come back, a 0% instalment against a card charged interest. This asks
// Claude Opus 5.5 to, on request.
//
// The app still does the arithmetic. It sends the figures it already
// computed — never the transaction history, never the names of people who
// owe the user — and the model writes the plan from them. Royal, metered on
// the Worker (analysis.js): one a month included, a second for 30 credits.

/// The plan, as the Worker returns it.
struct DebtAnalysis: Codable, Equatable {
    struct Step: Codable, Equatable {
        var title: String
        var detail: String
        var amount: String
        var when: String
    }
    var headline: String
    var summary: String
    var steps: [Step]
    var watchOut: [String]
    var question: String
    /// When the app received it.
    var createdAt: Date? = nil
}

// MARK: - What is sent

enum DebtAnalysisSnapshot {
    /// Below the Worker's 8000.
    static let limit = 7500

    struct Inputs {
        var cards: [BankCard]
        var installments: [CardInstallment]
        var debts: [DebtRecord]
        var receivables: [Receivable]
        var salaries: [SalarySchedule]
        var recurrings: [RecurringExpense]
        var goals: [SavingsGoal]
        var reading: DebtAffordability
        var advice: DebtFirstAdvice?
        var budget: (daily: Double, lifestyle: Double, investDebt: Double)
        var currency: String
        var now: Date = .now
    }

    /// The figures, in plain English for the model, each with what it means.
    /// Amounts are written as the app writes them, so the plan can quote them.
    @MainActor
    static func build(_ i: Inputs) -> String {
        let cm = CurrencyManager.shared
        let cur = i.currency
        let m = { (v: Double) in cm.formatted(v, currency: cur) }
        func toCur(_ v: Double, _ from: String) -> Double { cm.convert(v, from: from.isEmpty ? cur : from, to: cur) }
        let cal = Calendar.current
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        let monthYear = DateFormatter()
        monthYear.locale = Locale(identifier: "en_US_POSIX")
        monthYear.dateFormat = "MMM yyyy"
        let pct = { (v: Double) in "\(Int((v * 100).rounded()))%" }

        var lines = ["Currency: \(cur). Every figure below was computed by the app from the user's own records."]

        // The month.
        let r = i.reading
        if r.monthlyIncome > 0 {
            lines.append("Usual month (median of the last complete months, all accounts): income \(m(r.monthlyIncome)); living costs \(m(r.monthlySpending)).")
        } else {
            lines.append("Usual month: no income recorded yet.")
        }
        let categories = usualByCategory(cards: i.cards, currency: cur, now: i.now)
        if !categories.isEmpty {
            lines.append("Living costs by category, each its own usual month: "
                         + categories.prefix(9).map { "\($0.category.rawValue) \(m($0.amount))" }.joined(separator: "; ") + ".")
        }
        lines.append("Debt payments each month (minimums and instalments): \(m(r.monthlyPayments)).")
        if r.monthlyIncome > 0 {
            lines.append(r.left >= 0
                         ? "After a usual month and the payments: \(m(r.left)) left."
                         : "After a usual month and the payments: \(m(-r.left)) short.")
            if let v = r.verdict {
                lines.append("The app's verdict: \(word(v)); payments take \(pct(r.paymentShare)) of income.")
            }
        }
        let bills = i.recurrings.filter(\.isActive)
        if !bills.isEmpty {
            lines.append("Fixed bills the user declared: "
                         + bills.prefix(10).map { "\($0.label) \(m(toCur($0.amount, $0.currency)))" }.joined(separator: "; ") + ".")
        }

        // What is owed.
        for d in i.debts where d.isActive && !d.manuallyClosed && d.currentBalance > 0 {
            var s = "Debt '\(d.name)' (\(d.type.replacingOccurrences(of: "_", with: " "))): owes \(m(toCur(d.currentBalance, d.currency))), \(rate(d.annualInterestRate)) a year, minimum \(m(toCur(d.effectiveMinimumPayment, d.currency))) a month"
            if let months = d.monthsToPayoffMinimum, let end = cal.date(byAdding: .month, value: months, to: i.now) {
                s += ", paid off around \(monthYear.string(from: end)) at the minimum"
            } else {
                s += ", never paid off at the minimum"
            }
            lines.append(s + ".")
        }
        let thisMonth = cal.date(from: cal.dateComponents([.year, .month], from: i.now)) ?? i.now
        let lastMonth = cal.date(byAdding: .month, value: -1, to: thisMonth) ?? thisMonth
        for card in i.cards where card.isCreditCard {
            let b = card.bill(i.installments)
            guard b.total >= 0.5 else { continue }
            let cc = card.resolvedCurrency
            let mc = { (v: Double) in cm.formatted(v, currency: cc) }
            var parts = ["owes \(mc(b.total)) in total"]
            let carried = ObligationLoad.carried(on: card, since: lastMonth)
            if carried >= 0.5 { parts.append("\(mc(carried)) of it carried over from earlier bills and charged interest") }
            if b.installmentDue >= 0.5 { parts.append("\(mc(b.installmentDue)) of instalments billed and not paid yet") }
            if b.locked >= 0.5 { parts.append("\(mc(b.locked)) of instalment principal not billed yet") }
            if card.creditLimit > 0 { parts.append("limit \(mc(card.creditLimit))") }
            let name = card.holderName.isEmpty ? "credit card" : card.holderName
            lines.append("Credit card '\(name)': " + parts.joined(separator: "; ") + ".")
            for inst in i.installments where inst.cardID == card.id && inst.isActive && !inst.isFinished {
                lines.append("  Instalment '\(inst.merchant)' on it: \(cm.formatted(inst.monthlyAmount, currency: inst.currency)) a month, \(inst.remainingCount(asOf: i.now)) of \(inst.tenorMonths) months left, \(rate(inst.flatRatePercent)) a year flat.")
            }
        }

        // What is owed back — amounts and dates, never who.
        let allTx = i.cards.flatMap(\.transactions)
        let open = i.receivables.filter { !$0.isSettled }
            .map { (loan: $0, amount: toCur($0.outstanding(from: allTx), $0.currency)) }
            .filter { $0.amount >= 0.5 }
            .sorted { $0.loan.lentAt < $1.loan.lentAt }
        if !open.isEmpty {
            let total = open.reduce(0.0) { $0 + $1.amount }
            lines.append("Money owed to the user by others — one-off when repaid, never income: \(m(total)) across \(open.count) loan(s).")
            for (n, item) in open.prefix(8).enumerated() {
                var s = "  Loan \(n + 1): \(m(item.amount)), lent \(day.string(from: item.loan.lentAt))"
                if let due = item.loan.dueDate {
                    s += ", to be repaid by \(day.string(from: due))" + (item.loan.isOverdue ? " (overdue)" : "")
                } else {
                    s += ", no repayment date agreed"
                }
                lines.append(s + ".")
            }
        }

        // The buffer, and the plan.
        let usual = LadderInputs.gather(cards: i.cards, debts: i.debts, holdings: [], goals: i.goals,
                                        salaries: i.salaries, currency: cur, installments: i.installments, now: i.now)
        let cash = max(usual.cash, 0)
        lines.append("Cash in bank accounts and wallets (not credit cards): \(m(cash)).")
        if usual.monthlyEssentials > 0 {
            lines.append("Daily needs in a usual month: \(m(usual.monthlyEssentials)); the cash covers \(String(format: "%.1f", cash / usual.monthlyEssentials)) months of them.")
        }
        lines.append("Smart Budget plan: daily needs \(pct(i.budget.daily)), lifestyle \(pct(i.budget.lifestyle)), savings & debt \(pct(i.budget.investDebt)) of income.")
        if let advice = i.advice {
            let title = LanguageManager.shared.withLanguage(.english) { advice.title() }
            lines.append("The app's Smart Budget advice on this screen: \"\(title)\".")
        }
        for g in i.goals where !g.isCompleted {
            lines.append("Savings goal '\(g.name)': \(m(toCur(g.savedAmount, g.currency))) saved of \(m(toCur(g.targetAmount, g.currency))).")
        }

        let text = lines.joined(separator: "\n")
        return text.count > limit ? String(text.prefix(limit)) : text
    }

    /// Each living-cost category's usual month: the median of the last
    /// complete months, the same window and rule as the Financial ladder.
    @MainActor
    static func usualByCategory(cards: [BankCard], currency: String, now: Date,
                                cal: Calendar = .current) -> [(category: TxCategory, amount: Double)] {
        let cm = CurrencyManager.shared
        let living = Set(SmartBudgetManager.dailyCategories + SmartBudgetManager.lifestyleCategories)
        let all = cards.flatMap(\.transactions)
        let first = all.map(\.date).min() ?? now
        let spent = all.filter {
            $0.amount < 0 && $0.txSubtype == .normal && living.contains($0.category)
                && $0.oneOffOverride != true && $0.date <= now
        }
        var out: [(category: TxCategory, amount: Double)] = []
        for category in living {
            let items = spent.filter { $0.category == category }.map {
                (date: $0.date, amount: cm.convert(abs($0.amount), from: $0.currency.isEmpty ? currency : $0.currency, to: currency))
            }
            let months = FinancialLadder.completeMonthTotals(items, count: 3, firstActivity: first, now: now, cal: cal)
            let usual = FinancialLadder.median(months)
            if usual >= 0.5 { out.append((category, usual)) }
        }
        return out.sorted { $0.amount > $1.amount }
    }

    private static func word(_ v: DebtAffordability.Verdict) -> String {
        switch v {
        case .safe:  return "Safe"
        case .tight: return "Tight"
        case .heavy: return "Too heavy"
        }
    }

    private static func rate(_ r: Double) -> String {
        "\(DebtFirstAdvice.rate(r))%"
    }
}

// MARK: - Asking for it

@MainActor
@Observable
final class DebtAnalysisClient {
    static let shared = DebtAnalysisClient()

    private static let analyzeURL = URL(string: "https://dipo-receipt-scanner.fahmi-aquinas.workers.dev/api/analyze-debt")!
    private static let creditsURL = URL(string: "https://dipo-receipt-scanner.fahmi-aquinas.workers.dev/api/credits")!

    enum Failure: Error, Equatable {
        /// `confirm`: logged in, but the Firebase account on this phone
        /// doesn't carry that login (see AccountReconnect.bind).
        case offline, signIn, confirm, royal, limit, credits, declined, generic

        var messageKey: String {
            switch self {
            case .offline:  return "analysis.err.offline"
            case .signIn:   return "analysis.err.signin"
            case .confirm:  return "analysis.err.confirm"
            case .royal:    return "analysis.err.royal"
            case .limit:    return "analysis.err.limit"
            case .credits:  return "analysis.err.credits"
            case .declined: return "analysis.err.declined"
            case .generic:  return "analysis.err.generic"
            }
        }
    }

    /// This month's analyses, as the Worker counts them.
    struct Quota: Equatable {
        var used: Int
        var cap: Int
        /// Credits the next one costs: 0 while the included one is unused,
        /// nil once the month's cap is reached.
        var nextCost: Int?
        var balance: Int
    }

    var quota: Quota?
    private(set) var isRunning = false
    private(set) var last: DebtAnalysis?
    /// Logged in, but this phone's Firebase account doesn't carry the login
    /// yet, so the Worker would refuse: the card asks for one confirmation.
    private(set) var needsAccount = false
    private(set) var isConfirming = false

    /// Its own session. The shared one gives up after 30 seconds and tries
    /// again up to three times — fine for a chat message, but here each
    /// attempt is a Claude Opus 5.5 run, and one that thinks for 40 seconds
    /// would be paid for three times and then reported as failed.
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 150
        config.timeoutIntervalForResource = 180
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    private struct AnalyzeBody: Encodable { let userId, snapshot, language: String }
    private struct AnalyzeReply: Decodable {
        let analysis: DebtAnalysis
        let analysesUsed: Int
        let analysesCap: Int
        let nextCost: Int?
        let creditsLeft: Int
    }
    private struct CreditsReply: Decodable {
        let balance: Int
        let analysesUsed: Int?
        let analysesCap: Int?
        let nextAnalysisCost: Int?
    }
    private struct ErrorReply: Decodable { let error: String? }

    private static func storeKey(_ userId: String) -> String { "debt_analysis_last.\(userId)" }

    /// Royal first: for anyone else, confirming the account would only lead
    /// to "the analysis is part of Royal".
    func checkAccount() {
        needsAccount = UserSession.shared.isLoggedIn && PremiumManager.shared.plan == .royal
            && !AccountReconnect.isBound
    }

    func confirmAccount() async -> AccountReconnect.BindOutcome {
        guard !isConfirming else { return .cancelled }
        isConfirming = true
        defer { isConfirming = false }
        let outcome = await AccountReconnect.bind()
        if outcome == .bound { needsAccount = false }
        return outcome
    }

    /// The last plan this account received on this phone.
    func loadLast() {
        guard let userId = UserSession.shared.userID,
              let sealed = UserDefaults.standard.string(forKey: Self.storeKey(userId)) else { last = nil; return }
        last = Self.open(sealed)
    }

    /// A plan names the person's debts and what they owe, and UserDefaults
    /// is a plain file in the app's container and its backups — so it is
    /// kept sealed with the app's Keychain key, like card numbers are.
    static func seal(_ analysis: DebtAnalysis) -> String? {
        guard let json = try? JSONEncoder().encode(analysis),
              let text = String(data: json, encoding: .utf8) else { return nil }
        let sealed = CryptoManager.shared.encrypt(text)
        return sealed.isEmpty ? nil : sealed
    }

    static func open(_ sealed: String) -> DebtAnalysis? {
        let text = CryptoManager.shared.decrypt(sealed)
        guard !text.isEmpty else { return nil }
        return try? JSONDecoder().decode(DebtAnalysis.self, from: Data(text.utf8))
    }

    private func request(_ url: URL, body: Data?) async -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in await WorkerAuth.headers() { req.setValue(value, forHTTPHeaderField: key) }
        req.httpBody = body
        return req
    }

    func refreshQuota() async {
        guard let userId = UserSession.shared.userID, NetworkService.shared.isOnline,
              let body = try? JSONEncoder().encode(["userId": userId]) else { return }
        let req = await request(Self.creditsURL, body: body)
        guard let result = try? await session.data(for: req),
              (result.1 as? HTTPURLResponse)?.statusCode == 200,
              let reply = try? JSONDecoder().decode(CreditsReply.self, from: result.0),
              let cap = reply.analysesCap else { return }   // a Worker from before the analysis
        quota = Quota(used: reply.analysesUsed ?? 0, cap: cap, nextCost: reply.nextAnalysisCost, balance: reply.balance)
    }

    func run(snapshot: String) async -> Result<DebtAnalysis, Failure> {
        guard !isRunning else { return .failure(.generic) }
        guard let userId = UserSession.shared.userID else { return .failure(.signIn) }
        guard NetworkService.shared.isOnline else { return .failure(.offline) }
        isRunning = true
        defer { isRunning = false }

        let payload = AnalyzeBody(userId: userId, snapshot: snapshot, language: LanguageManager.shared.current.rawValue)
        guard let body = try? JSONEncoder().encode(payload) else { return .failure(.generic) }
        let req = await request(Self.analyzeURL, body: body)
        do {
            let (data, response) = try await session.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                let failure = Self.failure(status: status, body: data)
                if failure == .confirm {
                    // The Worker checks the account before the plan.
                    guard PremiumManager.shared.plan == .royal else { return .failure(.royal) }
                    needsAccount = true
                }
                return .failure(failure)
            }
            let reply = try JSONDecoder().decode(AnalyzeReply.self, from: data)
            var analysis = reply.analysis
            analysis.createdAt = .now
            if let sealed = Self.seal(analysis) {
                UserDefaults.standard.set(sealed, forKey: Self.storeKey(userId))
            }
            last = analysis
            quota = Quota(used: reply.analysesUsed, cap: reply.analysesCap, nextCost: reply.nextCost,
                          balance: reply.creditsLeft)
            return .success(analysis)
        } catch let error as URLError
                    where [URLError.Code.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed].contains(error.code) {
            return .failure(.offline)
        } catch {
            print("[DebtAnalysis] failed: \(error)")
            return .failure(.generic)
        }
    }

    /// What the Worker's answer means for the person waiting.
    static func failure(status: Int, body: Data) -> Failure {
        let error = (try? JSONDecoder().decode(ErrorReply.self, from: body))?.error
        switch status {
        case 401: return .confirm
        case 403: return .royal
        case 402: return error == "analysis_limit" ? .limit : .credits
        case 422: return .declined
        default:  return .generic
        }
    }
}

// MARK: - On the Debts screen

struct DebtAnalysisCard: View {
    /// Built when tapped, from the figures on the screen at that moment.
    let makeSnapshot: () -> String

    @State private var client = DebtAnalysisClient.shared
    @State private var showingPlan = false
    /// What went wrong, as a string key.
    @State private var problem: String?
    @State private var confirmingCost: Int?

    private var capped: Bool {
        if let q = client.quota { return q.nextCost == nil }
        return false
    }

    private var quotaLine: String? {
        guard let q = client.quota else { return nil }
        guard let cost = q.nextCost else {
            let cal = Calendar.current
            let thisMonth = cal.date(from: cal.dateComponents([.year, .month], from: .now)) ?? .now
            let next = cal.date(byAdding: .month, value: 1, to: thisMonth) ?? .now
            return String(format: loc("analysis.capped"),
                          next.formatted(.dateTime.day().month(.wide).locale(LanguageManager.shared.currentLocale)))
        }
        return cost == 0 ? loc("analysis.included") : String(format: loc("analysis.next_cost"), cost, q.balance)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(.subheadline, weight: .bold))
                    .foregroundStyle(AppTheme.accent)
                    .frame(width: 34, height: 34)
                    .background(AppTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: AppRadius.sm))
                VStack(alignment: .leading, spacing: 3) {
                    Text(loc("analysis.title"))
                        .font(.system(.body, weight: .bold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(loc("analysis.sub"))
                        .font(.system(.caption))
                        .foregroundStyle(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            if let last = client.last, let date = last.createdAt {
                Button {
                    HapticManager.shared.tap()
                    showingPlan = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text").font(.system(.caption, weight: .semibold))
                        Text(String(format: loc("analysis.last"), date.formatted(.dateTime.day().month(.abbreviated))))
                            .font(.system(.caption, weight: .semibold))
                        Spacer(minLength: 4)
                        Text(loc("analysis.view")).font(.system(.caption, weight: .bold))
                        Image(systemName: "chevron.right").font(.system(.caption2, weight: .bold))
                    }
                    .foregroundStyle(AppTheme.textPrimary)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(AppTheme.cardMid.opacity(0.6), in: RoundedRectangle(cornerRadius: AppRadius.sm))
                }
                .buttonStyle(ScaleButtonStyle())
            }

            if client.needsAccount {
                confirmButton
            } else {
                runButton
            }

            if client.isRunning {
                Text(loc("analysis.working"))
                    .font(.system(.caption))
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let problem {
                Label(loc(problem), systemImage: "exclamationmark.circle.fill")
                    .font(.system(.caption, weight: .medium))
                    .foregroundStyle(AppTheme.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if client.needsAccount {
                Text(loc("analysis.confirm_why"))
                    .font(.system(.caption))
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let quotaLine {
                Text(quotaLine)
                    .font(.system(.caption))
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(loc("analysis.privacy"))
                .font(.system(.caption2))
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.xl))
        .task {
            client.loadLast()
            client.checkAccount()
            await client.refreshQuota()
        }
        .alert(String(format: loc("analysis.confirm_title"), confirmingCost ?? 0),
               isPresented: Binding(get: { confirmingCost != nil }, set: { if !$0 { confirmingCost = nil } })) {
            Button(loc("analysis.confirm_go")) { confirmingCost = nil; go() }
            Button(loc("common.cancel"), role: .cancel) { confirmingCost = nil }
        } message: {
            Text(String(format: loc("analysis.confirm_msg"), confirmingCost ?? 0, client.quota?.balance ?? 0))
        }
        .sheet(isPresented: $showingPlan) {
            if let plan = client.last {
                DebtAnalysisSheet(analysis: plan)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(AppTheme.bg)
                    .preferredColorScheme(appColorScheme())
            }
        }
    }

    private var runButton: some View {
        Button(action: start) {
            HStack(spacing: 8) {
                if client.isRunning {
                    ProgressView().tint(AppTheme.onVividFill)
                } else {
                    Image(systemName: "wand.and.stars").font(.system(.subheadline, weight: .bold))
                }
                Text(loc(client.isRunning ? "analysis.working_short"
                         : (client.last == nil ? "analysis.run" : "analysis.run_again")))
                    .font(.system(.subheadline, weight: .bold))
            }
            .foregroundStyle(capped ? AppTheme.textSecondary : AppTheme.onVividFill)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(capped ? AppTheme.cardMid : AppTheme.accentFill, in: RoundedRectangle(cornerRadius: AppRadius.md))
        }
        .buttonStyle(ScaleButtonStyle())
        .disabled(client.isRunning || capped)
    }

    /// One sign-in with the same Apple ID or Google account, linked to this
    /// phone's account in place; then the analysis carries on.
    private var confirmButton: some View {
        let google = UserSession.shared.provider == .google
        return Button(action: confirm) {
            HStack(spacing: 8) {
                if client.isConfirming {
                    ProgressView().tint(AppTheme.onVividFill)
                } else {
                    Image(systemName: google ? "g.circle.fill" : "apple.logo")
                        .font(.system(.subheadline, weight: .bold))
                }
                Text(loc(client.isConfirming ? "analysis.confirming"
                         : (google ? "analysis.confirm_google" : "analysis.confirm_apple")))
                    .font(.system(.subheadline, weight: .bold))
            }
            .foregroundStyle(AppTheme.onVividFill)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(AppTheme.accentFill, in: RoundedRectangle(cornerRadius: AppRadius.md))
        }
        .buttonStyle(ScaleButtonStyle())
        .disabled(client.isConfirming)
    }

    private func confirm() {
        HapticManager.shared.tap()
        problem = nil
        Task {
            let outcome = await client.confirmAccount()
            switch outcome {
            case .bound:
                await client.refreshQuota()
                start()
                return
            case .cancelled:
                return
            case .otherAccount:  problem = "analysis.err.other_account"
            case .heldElsewhere: problem = "analysis.err.held_elsewhere"
            case .failed:        problem = "analysis.err.confirm_failed"
            }
            HapticManager.shared.warning()
        }
    }

    private func start() {
        HapticManager.shared.tap()
        if let cost = client.quota?.nextCost, cost > 0 {
            confirmingCost = cost
        } else {
            go()
        }
    }

    private func go() {
        problem = nil
        let snapshot = makeSnapshot()
        Task {
            switch await client.run(snapshot: snapshot) {
            case .success:
                HapticManager.shared.success()
                showingPlan = true
            case .failure(let f):
                HapticManager.shared.warning()
                // Asked for by the confirm button and its line instead.
                problem = f == .confirm ? nil : f.messageKey
            }
        }
    }
}

// MARK: - The plan

struct DebtAnalysisSheet: View {
    let analysis: DebtAnalysis
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(analysis.headline)
                                .font(.system(.title3, weight: .bold))
                                .foregroundStyle(AppTheme.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            if !analysis.summary.isEmpty {
                                Text(analysis.summary)
                                    .font(.system(.subheadline))
                                    .foregroundStyle(AppTheme.textSecondary)
                                    .lineSpacing(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        if !analysis.steps.isEmpty {
                            section(loc("analysis.steps"))
                            VStack(spacing: 10) {
                                ForEach(Array(analysis.steps.enumerated()), id: \.offset) { n, step in
                                    stepRow(n + 1, step)
                                }
                            }
                        }

                        if !analysis.watchOut.isEmpty {
                            section(loc("analysis.watch"))
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(Array(analysis.watchOut.enumerated()), id: \.offset) { _, line in
                                    Label {
                                        Text(line).fixedSize(horizontal: false, vertical: true)
                                    } icon: {
                                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(AppTheme.orange)
                                    }
                                    .font(.system(.footnote))
                                    .foregroundStyle(AppTheme.textPrimary)
                                }
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
                        }

                        if !analysis.question.isEmpty {
                            section(loc("analysis.question"))
                            Text(analysis.question)
                                .font(.system(.footnote))
                                .foregroundStyle(AppTheme.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
                        }

                        Text(String(format: loc("analysis.footer"),
                                    (analysis.createdAt ?? .now).formatted(.dateTime.day().month(.wide).year())))
                            .font(.system(.caption2))
                            .foregroundStyle(AppTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 30)
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 14)
                    .containerRelativeFrame(.horizontal)
                }
            }
            .navigationTitle(loc("analysis.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .doneToolbar { dismiss() }
        }
    }

    private func section(_ title: String) -> some View {
        Text(title.uppercased(with: LanguageManager.shared.currentLocale))
            .font(.system(.caption, weight: .bold))
            .tracking(1)
            .foregroundStyle(AppTheme.textSecondary)
    }

    private func stepRow(_ n: Int, _ step: DebtAnalysis.Step) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)")
                .font(.system(.footnote, weight: .bold))
                .foregroundStyle(n == 1 ? AppTheme.onVividFill : AppTheme.textSecondary)
                .frame(width: 26, height: 26)
                .background(n == 1 ? AppTheme.accentFill : AppTheme.cardMid.opacity(0.8), in: Circle())
            VStack(alignment: .leading, spacing: 5) {
                Text(step.title)
                    .font(.system(.subheadline, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(step.detail)
                    .font(.system(.footnote))
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    if !step.amount.isEmpty { pill(step.amount, tint: AppTheme.accent) }
                    if !step.when.isEmpty { pill(step.when, tint: AppTheme.textSecondary) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
    }

    private func pill(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(.caption2, weight: .semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(tint.opacity(0.12), in: Capsule())
    }
}
