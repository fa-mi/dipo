import XCTest
import SwiftData
@testable import DiPo

/// A row recorded as spending that was really a loan, and money in that was
/// really someone paying back — joined to the receivable after the fact.
@MainActor
final class ReceivableConversionTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }

    override func setUpWithError() throws {
        let schema = Schema(versionedSchema: DiPoSchemaCurrent.self)
        container = try ModelContainer(for: schema,
                                       configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    }

    private func day(_ m: Int, _ d: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: m, day: d, hour: 10))!
    }

    private func tx(_ name: String, _ amount: Double, on date: Date = .now,
                    category: TxCategory = .other, notes: String = "") -> TxRecord {
        let t = TxRecord(name: name, date: date, amount: amount,
                         type: amount < 0 ? "tx.type.purchase" : "tx.type.income", icon: "X",
                         iconBgHex: category.iconBg, category: category, currency: "IDR", notes: notes)
        context.insert(t)
        return t
    }

    func testNamesAreGuessedFromTheRow() {
        XCTAssertEqual(ReceivableConversion.guessName(from: "hutang ke ibuk"), "Ibuk")
        XCTAssertEqual(ReceivableConversion.guessName(from: "Cipa Hutang"), "Cipa")
        XCTAssertEqual(ReceivableConversion.guessName(from: "tf ke Budi santoso"), "Budi santoso")
        XCTAssertEqual(ReceivableConversion.guessName(from: "pinjaman"), "pinjaman", "never empty")
    }

    func testOnlyOrdinaryRowsQualify() {
        let loan = tx("hutang ke ibuk", -5_000_000, category: .commitment, notes: "nanti dikembalikan")
        XCTAssertTrue(ReceivableConversion.canLend(loan))

        let bill = tx("transfer mom", -1_000_000, category: .commitment, notes: "tx.note.recurring_auto")
        XCTAssertFalse(ReceivableConversion.canLend(bill), "a recurring bill keeps its meaning")

        let move = tx("To BCA", -500_000); move.icon = "⇄"; move.txSubtype = .transfer
        XCTAssertFalse(ReceivableConversion.canLend(move))

        let back = tx("dari ibu", 5_000_000, category: .incomeOther)
        XCTAssertTrue(ReceivableConversion.canRepay(back))
        XCTAssertFalse(ReceivableConversion.canLend(back))

        let pay = tx("Gaji", 10_000_000, category: .salary)
        XCTAssertFalse(ReceivableConversion.canRepay(pay), "a salary is not a repayment")
    }

    func testANewReceivableTakesTheRowsAmountAndDate() {
        let loan = tx("hutang ke ibuk", -5_000_000, on: day(8, 18), category: .commitment,
                      notes: "nanti dikembalikan")
        let r = ReceivableConversion.lendNew(loan, personName: "Ibuk", context: context)

        XCTAssertEqual(r.personName, "Ibuk")
        XCTAssertEqual(r.amount, 5_000_000)
        XCTAssertEqual(r.lentAt, day(8, 18))
        XCTAssertEqual(loan.txSubtype, .transfer, "a loan is not spending")
        XCTAssertEqual(loan.linkedReceivableID, r.id.uuidString)
        XCTAssertEqual(loan.notes, "nanti dikembalikan", "the user's own note is kept")
        XCTAssertEqual(loan.amount, -5_000_000, "the balance does not move")
        XCTAssertEqual(r.outstanding(from: [loan]), 5_000_000, "the loan itself is not a repayment")
    }

    func testAnEmptyNoteGetsTheMarker() {
        let loan = tx("Cipa Hutang", -1_000_000)
        ReceivableConversion.lendNew(loan, personName: "", context: context)
        XCTAssertEqual(loan.notes, ReceivableConversion.lentNote)
    }

    /// Fahmi's case: "Mom" was written down on 4 October for Rp 10 jt; the
    /// Rp 5 jt that left on 18 August is most likely inside that figure.
    func testAttachingAnEarlierRowKeepsTheAmountByDefault() {
        let mom = Receivable(personName: "Mom", amount: 10_000_000, currency: "IDR", lentAt: day(10, 4))
        mom.createdAt = day(10, 4)
        context.insert(mom)
        let loan = tx("hutang ke ibuk", -5_000_000, on: day(8, 18))

        XCTAssertFalse(ReceivableConversion.addsToAmountByDefault(loan, receivable: mom))
        ReceivableConversion.lendAttach(loan, to: mom, addToAmount: false)
        XCTAssertEqual(mom.amount, 10_000_000)
        XCTAssertEqual(mom.lentAt, day(8, 18), "the claim dates from the earliest money out")
        XCTAssertEqual(loan.linkedReceivableID, mom.id.uuidString)
    }

    func testAttachingALaterRowAddsToTheAmount() {
        let dad = Receivable(personName: "Dad", amount: 5_000_000, currency: "IDR", lentAt: day(9, 1))
        dad.createdAt = day(9, 1)
        dad.isSettled = true
        context.insert(dad)
        let more = tx("tf ke dad", -2_000_000, on: day(9, 20))

        XCTAssertTrue(ReceivableConversion.addsToAmountByDefault(more, receivable: dad))
        ReceivableConversion.lendAttach(more, to: dad, addToAmount: true)
        XCTAssertEqual(dad.amount, 7_000_000)
        XCTAssertFalse(dad.isSettled, "more lending reopens it")
        XCTAssertEqual(dad.lentAt, day(9, 1))
    }

    func testARepaymentStopsBeingIncomeAndSettlesWhenItCoversTheRest() {
        let mom = Receivable(personName: "Mom", amount: 5_000_000, currency: "IDR")
        context.insert(mom)
        let half = tx("dari ibu", 2_000_000, category: .incomeOther)
        ReceivableConversion.repay(half, to: mom, allTx: [half])
        XCTAssertEqual(half.txSubtype, .transfer)
        XCTAssertEqual(half.notes, ReceivableConversion.repaidNote)
        XCTAssertFalse(mom.isSettled)
        XCTAssertEqual(mom.outstanding(from: [half]), 3_000_000)

        let rest = tx("ibu lunas", 3_000_000, category: .incomeOther)
        ReceivableConversion.repay(rest, to: mom, allTx: [half])
        XCTAssertTrue(mom.isSettled, "counts the row even when the list predates it")
    }

    func testLikelyMatchFindsTheClaimByName() {
        let dad = Receivable(personName: "Dad", amount: 1, currency: "IDR")
        let cipa = Receivable(personName: "Cipa", amount: 1, currency: "IDR")
        XCTAssertEqual(ReceivableConversion.likelyMatch(for: "Cipa Hutang", in: [dad, cipa])?.id, cipa.id)
        XCTAssertNil(ReceivableConversion.likelyMatch(for: "hutang ke ibuk", in: [dad, cipa]))
    }

    func testUndoingARowThatMadeItsOwnClaimRemovesTheClaim() throws {
        let loan = tx("Cipa Hutang", -1_000_000, on: day(8, 25))
        let r = ReceivableConversion.lendNew(loan, personName: "Cipa", context: context)
        try context.save()

        let removed = ReceivableConversion.unlink(loan, receivables: [r], allTx: [loan], context: context)
        try context.save()
        XCTAssertTrue(removed)
        XCTAssertEqual(loan.txSubtype, .normal, "spending again")
        XCTAssertEqual(loan.linkedReceivableID, "")
        XCTAssertEqual(loan.notes, "", "the marker goes with the link")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Receivable>()), 0)
    }

    func testUndoingOneRowOfALargerClaimKeepsTheClaim() throws {
        let mom = Receivable(personName: "Mom", amount: 10_000_000, currency: "IDR", lentAt: day(10, 4))
        context.insert(mom)
        let loan = tx("hutang ke ibuk", -5_000_000, on: day(8, 18), notes: "nanti dikembalikan")
        ReceivableConversion.lendAttach(loan, to: mom, addToAmount: false)

        XCTAssertFalse(ReceivableConversion.unlink(loan, receivables: [mom], allTx: [loan], context: context))
        XCTAssertEqual(mom.amount, 10_000_000)
        XCTAssertEqual(loan.notes, "nanti dikembalikan")
        XCTAssertEqual(loan.txSubtype, .normal)
    }

    func testUndoingARepaymentReopensASettledClaim() {
        let mom = Receivable(personName: "Mom", amount: 5_000_000, currency: "IDR")
        context.insert(mom)
        let back = tx("dari ibu", 5_000_000, category: .incomeOther)
        ReceivableConversion.repay(back, to: mom, allTx: [back])
        XCTAssertTrue(mom.isSettled)

        ReceivableConversion.unlink(back, receivables: [mom], allTx: [back], context: context)
        XCTAssertFalse(mom.isSettled)
        XCTAssertEqual(back.txSubtype, .normal, "income again")
    }

    /// Backups used to drop the link, so a restored repayment stopped
    /// counting against its loan.
    func testBackupsKeepTheReceivableLink() throws {
        let row = BackupTransaction(id: UUID(), cardID: UUID(), name: "Repaid by Mom", date: day(10, 4),
                                    amount: 5_000_000, type: "tx.type.income", icon: "MO",
                                    iconBgHex: "#000000", categoryRaw: "Other Income", currency: "IDR",
                                    notes: ReceivableConversion.repaidNote, linkedDebtID: "",
                                    subtype: "transfer", linkedReceivableID: "ABC")
        let data = try JSONEncoder().encode(row)
        XCTAssertEqual(try JSONDecoder().decode(BackupTransaction.self, from: data).linkedReceivableID, "ABC")

        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        old.removeValue(forKey: "linkedReceivableID")
        let oldData = try JSONSerialization.data(withJSONObject: old)
        XCTAssertEqual(try JSONDecoder().decode(BackupTransaction.self, from: oldData).linkedReceivableID, "",
                       "older backups still open")
    }

    func testStringsExist() {
        for key in ["tx.loan.make", "tx.loan.repay", "tx.loan.linked", "tx.loan.unlink_msg_lent",
                    "loan.intro_lend", "loan.intro_repay", "loan.counted_q", "loan.after_left"] {
            XCTAssertNotEqual(loc(key), key, "missing \(key)")
        }
    }
}
