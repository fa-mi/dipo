import XCTest
import SwiftData
@testable import DiPo

/// The web dashboard's hero said "Over budget this cycle" in red while the
/// phone said "Safe until payday". The sync now carries the phone's own
/// headline — figures and sentences — so the two read the same.
@MainActor
final class WebPeriodViewTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }

    override func setUpWithError() throws {
        let schema = Schema(versionedSchema: DiPoSchemaCurrent.self)
        container = try ModelContainer(for: schema,
                                       configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    }

    private func card(_ holder: String, _ number: String, balance: Double = 0) -> BankCard {
        let c = BankCard(holderName: holder, cardNumber: number, balance: balance,
                         expireDate: "11/29", gradientStart: "#000000", gradientEnd: "#111111",
                         sortOrder: 0, currency: "IDR")
        context.insert(c)
        return c
    }

    private func day(_ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: m, day: d, hour: h, minute: min))!
    }

    private func row(_ name: String, _ amount: Double, _ date: Date, _ cat: TxCategory = .other,
                     subtype: TxSubtype = .normal, icon: String = "X", notes: String = "") -> TxRecord {
        let t = TxRecord(name: name, date: date, amount: amount,
                         type: amount < 0 ? "tx.type.purchase" : "tx.type.income", icon: icon,
                         iconBgHex: cat.iconBg, category: cat, currency: "IDR", notes: notes, subtype: subtype)
        context.insert(t)
        return t
    }

    private func words(_ v: [String: Any], _ lang: String) -> [String: Any] {
        v[lang] as? [String: Any] ?? [:]
    }

    /// The book's lines, added up the way they are printed.
    private func sum(_ lines: [[String: Any]]) -> (running: Double, end: Double) {
        var running = 0.0, end = 0.0
        for l in lines {
            let a = l["amount"] as? Double ?? 0
            switch l["op"] as? String {
            case "+": running += a
            case "−": running -= a
            case "=": end = a
            default:  running += a
            }
        }
        return (running, end)
    }

    /// Fahmi's cycle: salary Rp 10 jt, Rp 6,6 jt on living, Rp 3,88 jt to the
    /// credit card, and Mom's Rp 5 jt repayment arriving on 4 Oct.
    private func fahmisCycle() -> (BankCard, WebPeriodView.Cycle) {
        let bri = card("Fahmi", "5221845086220969")
        bri.transactions += [
            row("Carried in", 1_000_000, day(9, 20), .incomeOther),
            row("Main Salary", 10_000_000, day(9, 25, 1), .salary),
            row("Belanja", -4_500_000, day(9, 26), .shopping),
            row("Repaid by Mom", 5_000_000, day(10, 4, 18), .incomeOther, subtype: .transfer,
                notes: "tx.note.receivable_repaid"),
            row("Tokopedia CC bill payment", -2_000_000, day(10, 4, 19), .debtPayment),
            row("kos", -2_100_000, day(10, 8, 0), .bills),
            row("Tokopedia CC bill payment", -1_882_381, day(10, 8, 19), .debtPayment),
        ]
        let cycle = WebPeriodView.Cycle(start: day(9, 25, 0), now: day(10, 12), progress: (elapsed: 18, total: 30),
                                        projected: 12_000_000, previousSpent: 9_000_000,
                                        previousLiving: 5_700_000)
        return (bri, cycle)
    }

    /// In a cycle's first week a day or two decides any comparison, so the
    /// chip waits for the second. On payday a Rp 1,5 jt card bill and the
    /// day's shopping, against last cycle's first day, read "1020% more".
    func testTheFirstWeekHasNoComparison() throws {
        let bri = card("Fahmi", "5221845086220969")
        bri.transactions += [row("Main Salary", 10_000_000, day(10, 23, 0), .salary),
                             row("Tokopedia CC bill payment", -1_500_000, day(10, 23, 8), .debtPayment),
                             row("Makan", -225_000, day(10, 23, 20), .food)]
        let cycle = WebPeriodView.Cycle(start: day(10, 23, 0), now: day(10, 23, 21),
                                        progress: (elapsed: 1, total: 33),
                                        projected: nil, previousSpent: 154_000, previousLiving: 154_000)
        let v = try XCTUnwrap(WebPeriodView.payload(pot: [bri], cards: [bri], cycle: cycle,
                                                    currency: "IDR", extraIDs: []))
        XCTAssertEqual(v["living"] as? Double ?? 0, 225_000, accuracy: 0.5, "the card bill is not living")
        XCTAssertNil(v["change"])
        XCTAssertNil(words(v, "en")["change"])
    }

    func testTheWebGetsTheCalmReadingNotOverBudget() throws {
        let (bri, cycle) = fahmisCycle()
        let v = try XCTUnwrap(WebPeriodView.payload(pot: [bri], cards: [bri], cycle: cycle,
                                                    currency: "IDR", extraIDs: []))

        XCTAssertEqual(v["balance"] as? Double ?? 0, bri.computedBalance(), accuracy: 0.5,
                       "the hero's figure is the card's balance")
        XCTAssertEqual(v["balance"] as? Double ?? 0, 5_517_619, accuracy: 0.5)
        XCTAssertEqual(v["over"] as? Bool, false, "living costs stayed inside the salary")
        XCTAssertEqual(v["danger"] as? Bool, false)
        XCTAssertEqual(v["debtPaid"] as? Double ?? 0, 3_882_381, accuracy: 0.5)
        XCTAssertEqual(v["living"] as? Double ?? 0, 6_600_000, accuracy: 0.5,
                       "the card payment is not counted as living")

        // Payday: today's balance less the spending still to come.
        XCTAssertEqual(v["atPayday"] as? Double ?? 0, 4_000_000, accuracy: 0.5)
        XCTAssertEqual(v["safe"] as? Bool, true)
        XCTAssertEqual(v["paceOk"] as? Bool, true)
        XCTAssertEqual(v["timeMarker"] as? Double ?? 0, 0.6, accuracy: 0.0001)

        let id = words(v, "id"), en = words(v, "en")
        XCTAssertEqual(id["pill"] as? String, "Aman sampai gajian 25 Okt")
        XCTAssertEqual(id["debt"] as? String,
                       "Kamu juga bayar utang & kartu Rp 3.882.381. Itu mengurangi utang, bukan belanja baru. "
                       + "Dibantu Rp 482.381 dari Repaid by Mom.")
        XCTAssertEqual(en["living"] as? String,
                       "Spending & bills Rp 6.600.000 — still Rp 3.400.000 under your income.")
        XCTAssertEqual(en["change"] as? String, "16% vs last period")
        XCTAssertNotNil(en["cover"], "income ran out on 8 Oct; Mom's repayment paid the rest")
        XCTAssertNil(en["negStart"])
        XCTAssertNil(en["scope"], "no bill cards")
    }

    /// Every line is printed with its sign; added up they make the balance.
    func testTheBookAddsUpToTheBalanceInBothLanguages() throws {
        let (bri, cycle) = fahmisCycle()
        let v = try XCTUnwrap(WebPeriodView.payload(pot: [bri], cards: [bri], cycle: cycle,
                                                    currency: "IDR", extraIDs: []))
        for lang in ["en", "id"] {
            let lines = try XCTUnwrap(words(v, lang)["lines"] as? [[String: Any]])
            let total = sum(lines)
            XCTAssertEqual(total.running, total.end, accuracy: 0.5, lang)
            XCTAssertEqual(total.end, bri.computedBalance(), accuracy: 0.5, lang)
            XCTAssertEqual(lines.first(where: { $0["tone"] as? String == "accent" })?["label"] as? String,
                           "Repaid by Mom", "money in that isn't income, by name")
            XCTAssertEqual(lines.map { $0["kind"] as? String ?? "" },
                           ["start", "income", "in", "living", "debt", "end"], lang)
        }
        let idLabels = (words(v, "id")["lines"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
        XCTAssertTrue(idLabels.contains("Bayar utang & kartu kredit"))
        XCTAssertTrue(idLabels.contains("Saldo awal · 25 Sep"))
    }

    /// The payload goes to Firestore as is: only plain values.
    func testThePayloadIsPlainData() throws {
        let (bri, cycle) = fahmisCycle()
        let v = try XCTUnwrap(WebPeriodView.payload(pot: [bri], cards: [bri], cycle: cycle,
                                                    currency: "IDR", extraIDs: []))
        XCTAssertTrue(JSONSerialization.isValidJSONObject(v))
    }

    /// With a bill card, the pot is read as one: both balances, moves between
    /// them cancelled, and the subtitle names the bill card.
    func testBillCardsAreReadWithTheMainCard() throws {
        let bri = card("Fahmi", "5221845086220969", balance: 500_000)
        let bca = card("Fahmi", "4111111111119331", balance: 200_000)
        let ovo = card("OVO", "")
        ovo.isDigitalWallet = true
        ovo.walletProvider = "OVO"
        bri.transactions += [row("Gaji", 3_000_000, day(10, 1), .salary),
                             row("Transfer to BCA", -400_000, day(10, 2), subtype: .transfer, icon: "⇄")]
        bca.transactions += [row("Transfer from BRI", 400_000, day(10, 2).addingTimeInterval(0.2),
                                 subtype: .transfer, icon: "⇄"),
                             row("Listrik", -350_000, day(10, 3), .bills)]
        ovo.transactions.append(row("Transfer to BRI", -50_000, day(10, 4), subtype: .transfer, icon: "⇄"))
        bri.transactions.append(row("Transfer from OVO", 50_000, day(10, 4).addingTimeInterval(0.2),
                                    subtype: .transfer, icon: "⇄"))

        let cycle = WebPeriodView.Cycle(start: day(10, 1, 0), now: day(10, 12), progress: (elapsed: 12, total: 30),
                                        projected: nil, previousSpent: nil)
        let v = try XCTUnwrap(WebPeriodView.payload(pot: [bri, bca], cards: [bri, bca, ovo], cycle: cycle,
                                                    currency: "IDR", extraIDs: []))
        XCTAssertEqual(v["balance"] as? Double ?? 0, bri.computedBalance() + bca.computedBalance(), accuracy: 0.5)
        XCTAssertEqual(v["start"] as? Double ?? 0, 700_000, accuracy: 0.5)
        XCTAssertNil(v["safe"], "nothing to project from")

        let en = words(v, "en")
        // Both cards say only "Fahmi", so the name stays whole and the digits
        // tell them apart.
        XCTAssertEqual(en["scope"] as? String, "With the cards it pays bills from · Fahmi ••9331")
        let own = (en["lines"] as? [[String: Any]] ?? []).first { $0["details"] != nil }
        let details = try XCTUnwrap(own?["details"] as? [[String: Any]])
        XCTAssertEqual(details.count, 1, "BRI↔BCA cancels inside the pot; only OVO is left")
        XCTAssertEqual(details.first?["label"] as? String, "From OVO")
        XCTAssertEqual(details.first?["amount"] as? Double ?? 0, 50_000, accuracy: 0.5)
    }

    func testNoIncomeYetSaysSoInsteadOfARatio() throws {
        let bri = card("Fahmi", "5221845086220969", balance: 2_000_000)
        bri.transactions.append(row("Makan", -50_000, day(10, 2), .food))
        let cycle = WebPeriodView.Cycle(start: day(10, 1, 0), now: day(10, 3), progress: (elapsed: 3, total: 30),
                                        projected: 500_000, previousSpent: nil)
        let v = try XCTUnwrap(WebPeriodView.payload(pot: [bri], cards: [bri], cycle: cycle,
                                                    currency: "IDR", extraIDs: []))
        XCTAssertNil(words(v, "en")["living"])
        XCTAssertNil(words(v, "en")["pace"])
        XCTAssertEqual(words(v, "id")["noIncome"] as? String,
                       "Belum ada pemasukan tercatat di periode ini, jadi pengeluaran belum bisa dibandingkan.")
    }

    /// A debit account can't open below zero; the web says what that means.
    func testANegativeOpeningIsExplained() throws {
        let bri = card("Fahmi", "5221845086220969", balance: 0)
        bri.transactions += [row("Belanja lama", -300_000, day(9, 20), .shopping),
                             row("Gaji", 1_000_000, day(10, 1), .salary)]
        let cycle = WebPeriodView.Cycle(start: day(10, 1, 0), now: day(10, 3), progress: nil,
                                        projected: nil, previousSpent: nil)
        let v = try XCTUnwrap(WebPeriodView.payload(pot: [bri], cards: [bri], cycle: cycle,
                                                    currency: "IDR", extraIDs: []))
        XCTAssertNotNil(words(v, "en")["negStart"])
        XCTAssertNil(v["timeMarker"], "a finished cycle has no tick")
    }

    func testExtraFundsAreCountedOnlyWhenFlagged() throws {
        let bri = card("Fahmi", "5221845086220969")
        let mom = row("Repaid by Mom", 1_000_000, day(10, 2), .incomeOther, subtype: .transfer)
        bri.transactions += [row("Gaji", 1_000_000, day(10, 1), .salary), mom,
                             row("Belanja", -1_500_000, day(10, 3), .shopping)]
        let cycle = WebPeriodView.Cycle(start: day(10, 1, 0), now: day(10, 5), progress: nil,
                                        projected: nil, previousSpent: nil)
        let plain = try XCTUnwrap(WebPeriodView.payload(pot: [bri], cards: [bri], cycle: cycle,
                                                        currency: "IDR", extraIDs: []))
        XCTAssertEqual(plain["over"] as? Bool, true)
        let added = try XCTUnwrap(WebPeriodView.payload(pot: [bri], cards: [bri], cycle: cycle,
                                                        currency: "IDR", extraIDs: [mom.id.uuidString]))
        XCTAssertEqual(added["over"] as? Bool, false)
        XCTAssertEqual(added["livingFunds"] as? Double ?? 0, 2_000_000, accuracy: 0.5)
    }

    /// The line the dashboard draws: one balance per day, ending on today's,
    /// with the days money came in or paid a debt marked by kind.
    func testTheTrailEndsOnTodaysBalanceAndMarksTheJumps() throws {
        let (bri, cycle) = fahmisCycle()
        let v = try XCTUnwrap(WebPeriodView.payload(pot: [bri], cards: [bri], cycle: cycle,
                                                    currency: "IDR", extraIDs: []))
        let trail = try XCTUnwrap(v["trail"] as? [Double])
        XCTAssertEqual(trail.count, 18, "25 Sep to 12 Oct, both included")
        XCTAssertEqual(trail.last ?? 0, bri.computedBalance(), accuracy: 0.5)
        XCTAssertEqual(trail.first ?? 0, 11_000_000, accuracy: 0.5, "carried in, plus the salary that day")
        XCTAssertEqual(v["elapsedDays"] as? Int, 18)
        XCTAssertEqual(v["totalDays"] as? Int, 30)

        let marks = try XCTUnwrap(v["marks"] as? [[String: Any]])
        let kinds = marks.map { "\($0["day"] as? Int ?? -1):\($0["kind"] as? String ?? "")" }
        XCTAssertEqual(kinds, ["0:income", "9:in", "9:debt", "13:debt"])
        XCTAssertEqual(marks[1]["amount"] as? Double ?? 0, 5_000_000, accuracy: 0.5)
        XCTAssertNil(marks.first { $0["name"] != nil }, "kinds only, never a name")
    }

    func testTheTrailIsCappedAndNeverEmpty() {
        let bri = card("Fahmi", "5221845086220969", balance: 100_000)
        let one = WebPeriodView.trail([], start: 100_000, from: day(10, 1), to: day(10, 1),
                                      convert: { $0.amount })
        XCTAssertEqual(one.balances, [100_000])
        let long = WebPeriodView.trail(bri.transactions, start: 0, from: day(1, 1), to: day(10, 1),
                                       convert: { $0.amount })
        XCTAssertEqual(long.balances.count, WebPeriodView.maxTrailDays)
    }

    // MARK: The shared words

    func testUsedPercentStaysBelowAHundredUntilIncomeIsGone() {
        XCTAssertEqual(PeriodCashBook.usedPct(ratio: 0.5), 50)
        XCTAssertEqual(PeriodCashBook.usedPct(ratio: 0.996), 99)
        XCTAssertEqual(PeriodCashBook.usedPct(ratio: 1), 100)
        XCTAssertEqual(PeriodCashBook.usedPct(ratio: 1.234), 123)
    }

    func testLivingSentenceSaysWhereTheGapCameFrom() {
        let rows = [row("Gaji", 1_000_000, day(10, 1), .salary),
                    row("Belanja", -1_500_000, day(10, 2), .shopping)]
        let book = PeriodCashBook.build(rows, start: 2_000_000, convert: { $0.amount })
        let text = LanguageManager.shared.withLanguage(.english) {
            book.livingSentence(money: { CurrencyManager.shared.formatted($0, currency: "IDR") })
        }
        XCTAssertEqual(text, "Spending & bills Rp 1.500.000 — Rp 500.000 over your income. "
                       + "It came out of money already on the card.")
    }
}
