import XCTest
import SwiftData
@testable import DiPo

/// The queue is the one place in DiPo where something the app READ becomes
/// something the user OWNS. Everything about that crossing is worth pinning:
/// nothing may reach the ledger unasked, and nothing may be lost on the way.
@MainActor
final class PendingInboxTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        let schema = Schema([
            BankCard.self, TxRecord.self, SalarySchedule.self,
            DebtRecord.self, SavingsGoal.self, RecurringExpense.self,
            Receivable.self, CardInstallment.self,
            CardBudgetConfig.self, CycleIntent.self, PendingTransaction.self
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: config)
        context = ModelContext(container)
    }

    override func tearDownWithError() throws {
        context = nil
        container = nil
    }

    private func makeCard() -> BankCard {
        let card = BankCard(holderName: "Test", cardNumber: "423456••••••7890",
                            balance: 0, expireDate: "12/30",
                            gradientStart: "#000000", gradientEnd: "#111111",
                            sortOrder: 0, currency: "IDR")
        context.insert(card)
        return card
    }

    private var ledger: [TxRecord] {
        (try? context.fetch(FetchDescriptor<TxRecord>())) ?? []
    }
    private var queue: [PendingTransaction] {
        (try? context.fetch(FetchDescriptor<PendingTransaction>())) ?? []
    }

    /// Capturing is not recording. This is the whole point of the queue.
    func testCaptureDoesNotTouchTheLedger() {
        let card = makeCard()
        PendingInbox.capture(name: "Warkop", amount: -4_000, currency: "IDR",
                             category: .food, cardID: card.id, source: .shortcut,
                             rawText: "BCA: Rp4.000 WARKOP", context: context)

        XCTAssertEqual(queue.count, 1)
        XCTAssertTrue(ledger.isEmpty, "A read transaction must not reach the ledger on its own.")
        XCTAssertTrue(card.transactions.isEmpty)
    }

    func testCommitMovesItToTheCard() throws {
        let card = makeCard()
        PendingInbox.capture(name: "Warkop", amount: -4_000, currency: "IDR",
                             category: .food, cardID: card.id, source: .shortcut,
                             context: context)
        let item = try XCTUnwrap(queue.first)

        XCTAssertTrue(PendingInbox.commit(item, cards: [card], context: context))

        XCTAssertEqual(card.transactions.count, 1)
        let tx = try XCTUnwrap(card.transactions.first)
        XCTAssertEqual(tx.name, "Warkop")
        XCTAssertEqual(tx.amount, -4_000, "The sign decides income vs expense; it must survive.")
        XCTAssertEqual(tx.category, .food)
        XCTAssertEqual(tx.currency, "IDR")
        XCTAssertEqual(tx.notes, "tx.note.from_inbox", "Stored keys, never translated text.")
        XCTAssertTrue(queue.isEmpty, "A committed row leaves the queue.")
    }

    /// The card is the one field nothing can guess. A row without one stays put
    /// rather than disappearing into nowhere.
    func testCommitRefusesWhenNoCardIsSet() throws {
        _ = makeCard()
        PendingInbox.capture(name: "Unknown", amount: -12_000, currency: "IDR",
                             cardID: nil, source: .backTap, context: context)
        let item = try XCTUnwrap(queue.first)

        XCTAssertFalse(PendingInbox.commit(item, cards: [], context: context))
        XCTAssertEqual(queue.count, 1, "It must survive a refused commit.")
        XCTAssertTrue(ledger.isEmpty)
    }

    /// A card deleted between capture and review leaves a dangling id.
    func testCommitRefusesWhenTheCardIsGone() throws {
        let card = makeCard()
        PendingInbox.capture(name: "Orphan", amount: -1_000, currency: "IDR",
                             cardID: card.id, source: .scan, context: context)
        let item = try XCTUnwrap(queue.first)
        context.delete(card)

        XCTAssertFalse(PendingInbox.commit(item, cards: [], context: context))
        XCTAssertEqual(queue.count, 1)
    }

    /// A top-up told from both ends, recorded as the move it was: the two
    /// legs the transfer form writes, at one time so they pair, and both rows
    /// gone from the queue.
    func testACrossedPairBecomesOneTransfer() throws {
        let bank = makeCard(), wallet = makeCard()
        PendingInbox.capture(name: "Top up GoPay", amount: -100_000, currency: "IDR",
                             cardID: bank.id, source: .notification, context: context)
        PendingInbox.capture(name: "Top up", amount: 100_000, currency: "IDR",
                             cardID: wallet.id, source: .notification, context: context)
        let rows = queue
        XCTAssertEqual(rows.count, 2)

        XCTAssertTrue(PendingInbox.commitTransfer(rows[0], rows[1], cards: [bank, wallet], context: context))
        try context.save()

        let out = try XCTUnwrap(bank.transactions.first)
        let into = try XCTUnwrap(wallet.transactions.first)
        XCTAssertEqual(out.amount, -100_000)
        XCTAssertEqual(into.amount, 100_000)
        XCTAssertEqual(out.txSubtype, .transfer)
        XCTAssertEqual(into.txSubtype, .transfer)
        XCTAssertEqual(out.date, into.date, "One moment, so Statistics pairs the legs.")
        XCTAssertTrue(NonFlowMovements.isOwnAccountMove(out, incoming: false))
        XCTAssertTrue(NonFlowMovements.isOwnAccountMove(into, incoming: true))
        XCTAssertTrue(queue.isEmpty)
    }

    /// Only one out and one in, on two different cards the user has.
    func testATransferNeedsTwoCardsAndBothWays() throws {
        let card = makeCard()
        PendingInbox.capture(name: "Out", amount: -50_000, currency: "IDR",
                             cardID: card.id, source: .notification, context: context)
        PendingInbox.capture(name: "In", amount: 50_000, currency: "IDR",
                             cardID: card.id, source: .notification, context: context)
        PendingInbox.capture(name: "No card", amount: 50_000, currency: "IDR",
                             cardID: nil, source: .notification, context: context)
        let out = try XCTUnwrap(queue.first { $0.name == "Out" })
        let into = try XCTUnwrap(queue.first { $0.name == "In" })
        let orphan = try XCTUnwrap(queue.first { $0.name == "No card" })

        XCTAssertFalse(PendingInbox.commitTransfer(out, into, cards: [card], context: context), "One card.")
        XCTAssertFalse(PendingInbox.commitTransfer(out, orphan, cards: [card], context: context), "No card.")
        XCTAssertFalse(PendingInbox.commitTransfer(into, orphan, cards: [card], context: context), "Both in.")
        XCTAssertEqual(queue.count, 3)
        XCTAssertTrue(ledger.isEmpty)
    }

    /// Income keeps its sign through the crossing too.
    func testIncomeStaysIncome() throws {
        let card = makeCard()
        PendingInbox.capture(name: "Refund", amount: 25_000, currency: "IDR",
                             category: .incomeOther, cardID: card.id,
                             source: .shortcut, context: context)
        let item = try XCTUnwrap(queue.first)

        XCTAssertTrue(PendingInbox.commit(item, cards: [card], context: context))
        XCTAssertEqual(card.transactions.first?.amount, 25_000)
        XCTAssertFalse(item.isExpense)
    }

    /// "Delete all" asks first, in both languages, saying how many go and
    /// that none of them is logged.
    func testDeleteAllSaysHowManyGo() {
        for language in [LanguageManager.Language.english, .indonesian] {
            LanguageManager.shared.withLanguage(language) {
                for key in ["pending.delete_all", "pending.delete_all_title",
                            "pending.delete_all_message", "pending.deleted_all"] {
                    XCTAssertNotEqual(loc(key), key, "missing \(key) in \(language)")
                }
                XCTAssertTrue(String(format: loc("pending.delete_all_message"), 12).contains("12"), "\(language)")
            }
        }
    }
}
