import XCTest
import SwiftData
@testable import DiPo

/// DiPo AI's debt analysis: what the app sends, and what it makes of the
/// Worker's answer.
@MainActor
final class DebtAnalysisTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }
    private let cal = Calendar.current

    override func setUpWithError() throws {
        let schema = Schema(versionedSchema: DiPoSchemaCurrent.self)
        container = try ModelContainer(for: schema,
                                       configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    private func spend(_ amount: Double, _ category: TxCategory, on card: BankCard, at when: Date) {
        let t = TxRecord(name: "x", date: when, amount: -amount, type: "tx.type.purchase", icon: "X",
                         iconBgHex: category.iconBg, category: category, currency: "IDR")
        context.insert(t)
        card.transactions.append(t)
    }

    /// Fahmi's figures, roughly: a bank account, the Tokopedia card with a
    /// carried balance and the iPad, a loan to a friend, kos, a goal.
    private func fahmi() -> DebtAnalysisSnapshot.Inputs {
        let now = date(2026, 10, 18)
        let bank = BankCard(holderName: "BRI", cardNumber: "5221845086220969", balance: 2_000_000, expireDate: "11/29",
                            gradientStart: "#000000", gradientEnd: "#111111", sortOrder: 0, currency: "IDR")
        let cc = BankCard(holderName: "Tokopedia CC", cardNumber: "5221845086220970", balance: 0, expireDate: "11/29",
                          gradientStart: "#000000", gradientEnd: "#111111", sortOrder: 1, currency: "IDR")
        cc.isCreditCard = true
        cc.creditLimit = 40_000_000
        cc.openingOwed = 5_250_000
        cc.creditSince = .distantPast
        [bank, cc].forEach(context.insert)
        spend(50_000, .food, on: bank, at: date(2026, 6, 5))
        for month in 7...9 {
            spend(3_000_000, .food, on: bank, at: date(2026, month, 10))
            spend(2_000_000, .shopping, on: bank, at: date(2026, month, 12))
        }
        let ipad = CardInstallment(cardID: cc.id, merchant: "iPad Air M3", totalAmount: 10_250_000, tenorMonths: 12,
                                   startDate: date(2026, 10, 9), currency: "IDR")
        ipad.createdAt = date(2026, 10, 9)
        context.insert(ipad)
        let salary = SalarySchedule(label: "Gaji", amount: 11_200_000, dayOfMonth: 25, currency: "IDR", cardID: bank.id)
        let loan = Receivable(personName: "Budi Santoso", amount: 3_000_000, currency: "IDR", lentAt: date(2026, 8, 18))
        let kos = RecurringExpense(label: "Kos", amount: 2_100_000, dayOfMonth: 1, currency: "IDR", cardID: bank.id)
        let goal = SavingsGoal(name: "Dana darurat", targetAmount: 30_000_000, savedAmount: 1_000_000)
        context.insert(salary); context.insert(loan); context.insert(kos); context.insert(goal)

        var advice = DebtFirstAdvice(share: 1_500_000, ratio: 0.15, minimums: 1_116_667, target: .card(carried: 5_250_000))
        advice.monthLeft = -2_102_467
        advice.owedToYou = 3_000_000
        return .init(cards: [bank, cc], installments: [ipad], debts: [], receivables: [loan], salaries: [salary],
                     recurrings: [kos], goals: [goal],
                     reading: DebtAffordability(monthlyIncome: 11_200_000, monthlySpending: 12_185_800,
                                                monthlyPayments: 1_116_667),
                     advice: advice, budget: (0.50, 0.35, 0.15), currency: "IDR", now: now)
    }

    // MARK: What is sent

    func testTheSnapshotCarriesTheFiguresTheScreenShows() {
        let s = DebtAnalysisSnapshot.build(fahmi())
        for expected in [
            "income Rp 11.200.000; living costs Rp 12.185.800",
            "Debt payments each month (minimums and instalments): Rp 1.116.667",
            "Rp 2.102.467 short",
            "The app's verdict: Too heavy",
            "Credit card 'Tokopedia CC'",
            "Rp 5.250.000 of it carried over from earlier bills and charged interest",
            "Instalment 'iPad Air M3' on it",
            "Loan 1: Rp 3.000.000, lent 2026-08-18, no repayment date agreed",
            "Fixed bills the user declared: Kos Rp 2.100.000",
            "Food & Drinks Rp 3.000.000",
            "Shopping Rp 2.000.000",
            "Smart Budget plan: daily needs 50%, lifestyle 35%, savings & debt 15%",
            "\"First spend less, then pay the card\"",
            "Savings goal 'Dana darurat'",
        ] {
            XCTAssertTrue(s.contains(expected), "missing: \(expected)\n\(s)")
        }
    }

    /// Who owes the user money is theirs to know, not the AI provider's.
    func testThePeopleWhoOweMoneyAreNotNamed() {
        let s = DebtAnalysisSnapshot.build(fahmi())
        XCTAssertFalse(s.contains("Budi"), s)
        XCTAssertFalse(s.contains("Santoso"), s)
    }

    func testTheSnapshotStaysUnderTheWorkersLimit() {
        var inputs = fahmi()
        for n in 0..<200 {
            inputs.recurrings.append(RecurringExpense(label: "Tagihan panjang sekali nomor \(n)", amount: 100_000,
                                                      dayOfMonth: 1, currency: "IDR"))
            inputs.goals.append(SavingsGoal(name: "Target yang namanya panjang \(n)", targetAmount: 1_000_000))
        }
        XCTAssertLessThanOrEqual(DebtAnalysisSnapshot.build(inputs).count, DebtAnalysisSnapshot.limit)
        XCTAssertLessThan(DebtAnalysisSnapshot.limit, 8000, "the Worker refuses longer")
    }

    // MARK: What comes back

    func testTheWorkersPlanDecodes() throws {
        let body = """
        {"headline":"Tutup kekurangan dulu.","summary":"Bulan biasa kurang Rp 2.102.467.",
         "steps":[{"title":"Kurangi belanja","detail":"Mulai dari Shopping.","amount":"Rp 2.102.467","when":"bulan ini"}],
         "watchOut":["Jangan tambah utang."],"question":""}
        """
        var plan = try JSONDecoder().decode(DebtAnalysis.self, from: Data(body.utf8))
        XCTAssertEqual(plan.steps.first?.amount, "Rp 2.102.467")
        XCTAssertNil(plan.createdAt)
        plan.createdAt = date(2026, 10, 18)
        let again = try JSONDecoder().decode(DebtAnalysis.self, from: JSONEncoder().encode(plan))
        XCTAssertEqual(again, plan, "kept on the phone as received")
    }

    /// Kept on the phone sealed: the stored text names no debt and no amount.
    func testTheKeptPlanIsSealed() throws {
        let plan = DebtAnalysis(headline: "Lunasi Tokopedia CC dulu.", summary: "Kartu membawa Rp 5.250.000.",
                                steps: [.init(title: "Bayar kartu", detail: "Mulai bulan ini.",
                                              amount: "Rp 5.250.000", when: "bulan ini")],
                                watchOut: [], question: "", createdAt: date(2026, 10, 18))
        let sealed = try XCTUnwrap(DebtAnalysisClient.seal(plan))
        XCTAssertFalse(sealed.contains("Tokopedia"))
        XCTAssertFalse(sealed.contains("5.250.000"))
        XCTAssertEqual(DebtAnalysisClient.open(sealed), plan)
        XCTAssertNil(DebtAnalysisClient.open("{\"headline\":\"plain\"}"), "plaintext is not taken as a plan")
    }

    /// Waited for, the answer is 200 at once, then spaces while Claude works,
    /// then the JSON with the real status in it.
    func testAWaitedAnswerCarriesItsStatusInItsBody() throws {
        let refused = Data("     {\"error\":\"declined\",\"status\":422}".utf8)
        XCTAssertEqual(DebtAnalysisClient.status(http: 200, body: refused), 422)
        XCTAssertEqual(DebtAnalysisClient.failure(status: 422, body: refused), .declined)
        XCTAssertEqual(DebtAnalysisClient.status(http: 402, body: Data("{\"error\":\"analysis_limit\"}".utf8)), 402,
                       "a check that failed before the wait, or a Worker from before")
        let plan = "   " + #"{"headline":"H","summary":"S","steps":[],"watchOut":[],"question":"","status":200}"#
        XCTAssertEqual(DebtAnalysisClient.status(http: 200, body: Data(plan.utf8)), 200)
        XCTAssertEqual(try JSONDecoder().decode(DebtAnalysis.self, from: Data(plan.utf8)).headline, "H",
                       "the spaces before it don't get in the way")
    }

    func testTheTimeShownWhileItWorks() {
        let start = date(2026, 10, 29)
        XCTAssertEqual(DebtAnalysisCard.elapsed(from: start, to: start), "0:00")
        XCTAssertEqual(DebtAnalysisCard.elapsed(from: start, to: start.addingTimeInterval(42)), "0:42")
        XCTAssertEqual(DebtAnalysisCard.elapsed(from: start, to: start.addingTimeInterval(125)), "2:05")
    }

    func testEachRefusalTellsThePersonWhatHappened() {
        let body = { (error: String) in Data("{\"error\":\"\(error)\"}".utf8) }
        XCTAssertEqual(DebtAnalysisClient.failure(status: 402, body: body("analysis_limit")), .limit)
        XCTAssertEqual(DebtAnalysisClient.failure(status: 402, body: body("out_of_credits")), .credits)
        XCTAssertEqual(DebtAnalysisClient.failure(status: 403, body: body("royal_required")), .royal)
        XCTAssertEqual(DebtAnalysisClient.failure(status: 401, body: body("unauthorized")), .confirm,
                       "logged in, but the phone's Firebase account doesn't carry the login: confirm it, don't log in again")
        XCTAssertEqual(DebtAnalysisClient.failure(status: 422, body: body("declined")), .declined)
        XCTAssertEqual(DebtAnalysisClient.failure(status: 502, body: Data()), .generic)
        XCTAssertEqual(DebtAnalysisClient.failure(status: 429, body: body("rate_limited")), .generic)
    }

    /// The card asks before an analysis that uses credits, going by the cost
    /// it last heard. A run cut off here can still finish on the Worker and
    /// be counted; the retry then costs 30 credits, and the Worker asks again
    /// instead of charging them.
    func testAnAnalysisThatNowCostsMoreIsAskedAboutAgain() throws {
        let changed = Data(#"{"error":"cost_changed","cost":30,"balance":60}"#.utf8)
        XCTAssertEqual(DebtAnalysisClient.failure(status: 409, body: changed), .costChanged(30))
        XCTAssertEqual(DebtAnalysisClient.failure(status: 409, body: Data(#"{"error":"cost_changed"}"#.utf8)), .generic,
                       "no cost to ask about")
        XCTAssertEqual(DebtAnalysisClient.failure(status: 409, body: Data(#"{"error":"other","cost":30}"#.utf8)), .generic)

        let sent = try JSONEncoder().encode(DebtAnalysisClient.AnalyzeBody(userId: "apple-1", snapshot: "S",
                                                                           language: "id", expectedCost: 30))
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: sent) as? [String: Any])
        XCTAssertEqual(fields["expectedCost"] as? Int, 30, "the name the Worker reads")
    }

    // MARK: Whose account the request may spend

    /// The Worker reads the Apple/Google identity out of the token; this is
    /// the same check made on the phone, to ask before the Worker refuses.
    func testTheLoginMustBeOnTheFirebaseAccount() {
        let apple = "001234.abcdef0123456789.0042"
        XCTAssertTrue(AccountReconnect.identityMatches(apple, providers: [("apple.com", apple)]))
        XCTAssertTrue(AccountReconnect.identityMatches("10987654321", providers: [("google.com", "10987654321")]))
        XCTAssertFalse(AccountReconnect.identityMatches(apple, providers: []), "the anonymous account from launch")
        XCTAssertFalse(AccountReconnect.identityMatches(apple, providers: [("apple.com", "001234.other.0042")]),
                       "another Apple ID")
        XCTAssertFalse(AccountReconnect.identityMatches(apple, providers: [("password", apple)]),
                       "only Apple and Google identities count, as on the Worker")
        XCTAssertFalse(AccountReconnect.identityMatches(nil, providers: [("apple.com", apple)]))
        XCTAssertFalse(AccountReconnect.identityMatches("", providers: [("apple.com", "")]))
    }

    // MARK: Words

    func testEveryStringExistsInBothLanguagesAndKeepsItsArguments() {
        let keys = ["analysis.title", "analysis.sub", "analysis.run", "analysis.run_again", "analysis.working_short",
                    "analysis.working", "analysis.included", "analysis.next_cost", "analysis.capped", "analysis.last",
                    "analysis.view", "analysis.confirm_title", "analysis.confirm_msg", "analysis.confirm_go",
                    "analysis.privacy", "analysis.steps", "analysis.watch", "analysis.question", "analysis.footer",
                    "analysis.err.offline", "analysis.err.signin", "analysis.err.royal", "analysis.err.limit",
                    "analysis.err.credits", "analysis.err.declined", "analysis.err.generic",
                    "analysis.err.confirm", "analysis.err.other_account", "analysis.err.held_elsewhere",
                    "analysis.err.confirm_failed", "analysis.confirm_apple", "analysis.confirm_google",
                    "analysis.confirming", "analysis.confirm_why", "analysis.err.interrupted", "analysis.err.slow"]
        let failures: [DebtAnalysisClient.Failure] = [.offline, .signIn, .confirm, .royal, .limit, .credits,
                                                      .declined, .generic, .interrupted, .slow, .costChanged(30)]
        for language in [LanguageManager.Language.english, .indonesian] {
            LanguageManager.shared.withLanguage(language) {
                for k in keys { XCTAssertNotEqual(loc(k), k, "\(k) in \(language)") }
                for f in failures { XCTAssertNotEqual(loc(f.messageKey), f.messageKey) }
                let cost = String(format: loc("analysis.next_cost"), 30, 45)
                XCTAssertTrue(cost.contains("30") && cost.contains("45"), cost)
                let confirm = String(format: loc("analysis.confirm_msg"), 30, 45)
                XCTAssertTrue(confirm.contains("30") && confirm.contains("45"), confirm)
                XCTAssertTrue(String(format: loc("analysis.working"), "1:05").contains("1:05"))
            }
        }
    }
}
