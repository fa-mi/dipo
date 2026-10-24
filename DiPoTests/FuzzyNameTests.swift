import XCTest
import SwiftData
@testable import DiPo

/// A name typed a letter off is read as the merchant it was aiming at, and
/// only then: a real word, a short word or the user's own habit is left alone.
@MainActor
final class FuzzyNameTests: XCTestCase {

    private var container: ModelContainer!

    override func setUpWithError() throws {
        let schema = Schema(versionedSchema: DiPoSchemaCurrent.self)
        container = try ModelContainer(for: schema,
                                       configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    }

    override func tearDownWithError() throws {
        container = nil
    }

    /// Past names, each written `times` times.
    private func history(_ entries: (String, Int)...) -> [String: FuzzyName.Known] {
        FuzzyName.vocabulary(of: entries.flatMap { Array(repeating: $0.0, count: $0.1) })
    }

    private func spent(_ name: String, _ category: TxCategory) -> TxRecord {
        let tx = TxRecord(name: name, date: .now, amount: -25_000, type: "tx.type.purchase", icon: "X",
                          iconBgHex: category.iconBg, category: category, currency: "IDR")
        container.mainContext.insert(tx)
        return tx
    }

    // MARK: What counts as a slip

    func testOneSlipUpToTenLettersAndTwoFromEleven() {
        XCTAssertEqual(FuzzyName.distance("indimaret", "indomaret", limit: 2), 1)
        XCTAssertEqual(FuzzyName.distance("shoppe", "shopee", limit: 2), 1, "Two swapped letters count once.")
        XCTAssertEqual(FuzzyName.distance("kitten", "sitting", limit: 5), 3)
        XCTAssertEqual(FuzzyName.distance("abc", "abcdef", limit: 1), 2, "Gives up past the limit.")
        XCTAssertTrue(FuzzyName.isTypo("indimaret", of: "indomaret"))
        XCTAssertTrue(FuzzyName.isTypo("alfamrt", of: "alfamart"))
        XCTAssertTrue(FuzzyName.isTypo("shoppe", of: "shopee"))
        XCTAssertTrue(FuzzyName.isTypo("loundry", of: "laundry"))
        XCTAssertFalse(FuzzyName.isTypo("indomrt", of: "indomaret"), "Two slips in nine letters.")
        XCTAssertTrue(FuzzyName.isTypo("suprmarkte", of: "supermarket"), "Two slips in eleven.")
    }

    func testShortWordsAndAnotherFirstLetterAreNeverSlips() {
        XCTAssertFalse(FuzzyName.isTypo("salah", of: "salad"))
        XCTAssertFalse(FuzzyName.isTypo("cooking", of: "booking"))
        XCTAssertFalse(FuzzyName.isTypo("samsul", of: "samsung"))
        XCTAssertFalse(FuzzyName.isTypo("indomaret", of: "indomaret"))
    }

    /// "pertama" is "first", not Pertamax; "renang" is swimming, not rendang.
    func testAWordInItsOwnRightIsNeverASlip() {
        XCTAssertFalse(FuzzyName.isTypo("pertama", of: "pertamax"))
        XCTAssertFalse(FuzzyName.isTypo("renang", of: "rendang"))
        XCTAssertFalse(FuzzyName.isTypo("keuangan", of: "kenangan"))
        XCTAssertFalse(FuzzyName.isTypo("computer", of: "commuter"))
        XCTAssertFalse(FuzzyName.isTypo("transport", of: "transmart"))
        XCTAssertTrue(FuzzyName.isWord("indomaret"), "A merchant DiPo knows.")
        XCTAssertTrue(FuzzyName.isWord("bensin"), "A word the chat parser knows.")
    }

    /// The list guards words DiPo doesn't know already, in the form they are
    /// checked in.
    func testTheCommonWordsAreLowercaseWordsDiPoDoesNotKnow() {
        XCTAssertTrue(FuzzyName.commonWords.isDisjoint(with: FuzzyName.knownWords))
        XCTAssertTrue(FuzzyName.commonWords.allSatisfy { $0.count >= 6 && $0 == $0.lowercased() })
    }

    func testAMerchantOfSeveralWordsIsMatchedWholeAndWordByWord() {
        XCTAssertTrue(FuzzyName.contains("beli kopi kenagan", typoOf: "kopi kenangan"))
        XCTAssertFalse(FuzzyName.contains("kenagan", typoOf: "kopi kenangan"))
        XCTAssertFalse(FuzzyName.contains("kopi keuangan", typoOf: "kopi kenangan"))
        XCTAssertFalse(FuzzyName.contains("transfer ika", typoOf: "transfer ibu"), "A short word has to be exact.")
    }

    // MARK: The name offered back

    func testASlipOfAMerchantIsOfferedInTheCaseItWasTyped() {
        XCTAssertEqual(FuzzyName.corrected("indimaret", history: [:]), "Indomaret")
        XCTAssertEqual(FuzzyName.corrected("indimaret 2", history: [:]), "Indomaret 2")
        XCTAssertEqual(FuzzyName.corrected("beli alfamrt", history: [:]), "beli alfamart")
        XCTAssertEqual(FuzzyName.corrected("ALFAMRT", history: [:]), "ALFAMART")
        XCTAssertEqual(FuzzyName.corrected("Kopi Kenagan", history: [:]), "Kopi Kenangan")
        XCTAssertEqual(FuzzyName.corrected("Kopi kenagan", history: [:]), "Kopi kenangan")
    }

    func testNothingIsOfferedForANameThatNeedsNothing() {
        for name in ["Indomaret", "kantin", "Budiman", "Kondangan", "Watsons", "Indomar",
                     "Deposit Bibit", "Salah transfer", "Obat batuk", "Cicilan pertama",
                     "Tiket renang", "Transport", "Laporan keuangan", "Electronic City", ""] {
            XCTAssertNil(FuzzyName.corrected(name, history: [:]), name)
        }
    }

    /// The user's own spelling, for a place DiPo doesn't know and for one
    /// it does.
    func testTheUsersOwnSpellingComesFirst() {
        XCTAssertEqual(FuzzyName.corrected("warung makmru", history: history(("Warung Makmur", 2))),
                       "warung Makmur")
        XCTAssertNil(FuzzyName.corrected("warung makmru", history: history(("Warung Makmur", 1))),
                     "Written once is not a habit yet.")
        let theirs = history(("INDOMARET", 2), ("Warung Bu Siti", 1))
        XCTAssertEqual(FuzzyName.corrected("indimaret", history: theirs), "INDOMARET")
        XCTAssertEqual(FuzzyName.corrected("warnug bu siti", history: theirs), "Warung bu siti")
    }

    func testAHabitStandsAndAOneOffGivesWay() {
        XCTAssertEqual(FuzzyName.corrected("indimaret", history: history(("indimaret", 1), ("Indomaret", 6))),
                       "Indomaret")
        XCTAssertEqual(FuzzyName.corrected("indimaret", history: history(("indimaret", 2))), "Indomaret",
                       "Twice still gives way to a merchant DiPo knows.")
        XCTAssertNil(FuzzyName.corrected("indimaret", history: history(("indimaret", 3))))
        XCTAssertNil(FuzzyName.corrected("makmru", history: history(("Makmru", 3), ("Makmur", 8))))
        XCTAssertEqual(FuzzyName.corrected("makmru", history: history(("Makmru", 3), ("Makmur", 9))), "Makmur")
        XCTAssertNil(FuzzyName.corrected("Indomaret", history: history(("Indomart", 5))),
                     "A merchant spelled right is never turned into the user's slip.")
    }

    // MARK: Categories

    func testASlipOfAKnownNameGetsItsCategory() {
        XCTAssertEqual(SmartBudgetManager.suggestCategory(for: "indimaret", txType: "Expense"), .food)
        XCTAssertEqual(SmartBudgetManager.suggestCategory(for: "Tokopedi", txType: "Expense"), .shopping)
        XCTAssertEqual(SmartBudgetManager.suggestCategory(for: "loundry", txType: "Expense"), .bills)
        XCTAssertNil(SmartBudgetManager.suggestCategory(for: "indimaret", txType: "Income"))
        for name in ["samsul", "Salah transfer", "pertama", "renang", "computer", "keuangan"] {
            XCTAssertNil(SmartBudgetManager.suggestCategory(for: name, txType: "Expense"), name)
        }
    }

    /// Their own Indomaret under Shopping outranks the shipped list's Food,
    /// slip or not, once it is a pattern.
    func testASlipLearnsFromTheWordTheUserWrote() throws {
        let past = (0..<3).map { _ in spent("Indomaret", .shopping) }
        let learned = try XCTUnwrap(SmartBudgetManager.learnedCategory(for: "indimaret", transactions: past))
        XCTAssertEqual(learned.category, .shopping)
        XCTAssertEqual(learned.matchedTerm, "indomaret")
        XCTAssertFalse(learned.isExact)
        XCTAssertNil(SmartBudgetManager.learnedCategory(for: "indimaret", transactions: Array(past.prefix(2))))
        XCTAssertEqual(SmartBudgetManager.suggestCategory(for: "indimaret", txType: "Expense", transactions: past),
                       .shopping)
    }

    func testTheChatParserReadsASlipOfItsWords() {
        XCTAssertEqual(LocalTxParser.parse("bensni 20rb")?.items.first?.category, .transport)
        XCTAssertEqual(LocalTxParser.parse("parkri 5rb")?.items.first?.category, .transport)
        XCTAssertEqual(LocalTxParser.parse("renang 20rb")?.items.first?.category, .other)
        XCTAssertEqual(LocalTxParser.parse("transfer ika 50rb")?.items.first?.category, .other)
    }
}
