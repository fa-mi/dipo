import XCTest
import SwiftData
@testable import DiPo

/// "Reset All Data" and the wipe when a different account signs in delete
/// every record of every model. Each used to keep its own list, and both
/// left money lent out, card instalments, investments, assets, spend-free
/// days, the daily totals and the review queue behind for the next person.
@MainActor
final class LocalDataWipeTests: XCTestCase {

    private func count<T: PersistentModel>(_ model: T.Type, in context: ModelContext) -> Int {
        (try? context.fetchCount(FetchDescriptor<T>())) ?? -1
    }

    func testNothingIsLeftOfAnyModel() throws {
        let schema = Schema(versionedSchema: DiPoSchemaCurrent.self)
        let container = try ModelContainer(for: schema,
                                           configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        let context = container.mainContext

        let card = BankCard(holderName: "Bank", cardNumber: "5221845086220969", balance: 0,
                            expireDate: "11/29", gradientStart: "#000000", gradientEnd: "#111111",
                            sortOrder: 0, currency: "IDR")
        context.insert(card)
        let tx = TxRecord(name: "Pupuk", date: .now, amount: -85_000, type: "tx.type.purchase", icon: "X",
                          iconBgHex: "#000000", category: .other, currency: "IDR")
        context.insert(tx)
        card.transactions.append(tx)
        context.insert(SavingsGoal(name: "Motor", targetAmount: 15_000_000, currency: "IDR"))
        // The ones the old lists left behind.
        context.insert(Receivable(personName: "Budi", amount: 500_000, currency: "IDR"))
        context.insert(CardInstallment(cardID: card.id, merchant: "Toko HP", totalAmount: 3_000_000,
                                       tenorMonths: 6, currency: "IDR"))
        let holding = InvestmentHolding(type: .gold, name: "Emas", currency: "IDR")
        context.insert(holding)
        let lot = InvestmentLot(kind: .buy, units: 1, pricePerUnit: 1_500_000)
        context.insert(lot)
        holding.lots.append(lot)
        context.insert(DayCheckIn(dayKey: "2026-10-25"))
        context.insert(PendingTransaction(name: "Transfer", amount: 50_000, currency: "IDR",
                                          rawText: "BRImo: Transfer Rp50.000 berhasil"))
        context.insert(PhysicalAsset(kind: .motorcycle, name: "Beat", currency: "IDR",
                                     purchasePrice: 18_000_000, purchaseDate: .now))
        context.insert(HeldWant(name: "Sepatu lari", amount: 450_000, currency: "IDR", waitDays: 3))
        try context.save()
        RollupStore.shared.rebuild(context: context)
        XCTAssertGreaterThan(count(DailyRollup.self, in: context), 0, "The daily totals are filled in.")
        XCTAssertGreaterThan(count(PendingTransaction.self, in: context), 0)

        LocalDataWipe.deleteAllRecords(in: context)

        for model in DiPoSchemaCurrent.models {
            XCTAssertEqual(count(model, in: context), 0, "\(model) left behind")
        }
        XCTAssertTrue(RollupStore.shared.buckets.isEmpty, "The totals in memory went with the store.")
    }

    /// The pushes that go with the data name it; the daily check-in doesn't.
    func testThePushesThatGoAreTheOnesAboutRecords() {
        let prefixes = LocalDataWipe.reminderPrefixes
        for id in ["smart_debt_due_1", "card_expiry_ABC", "salary_reminder_3d", "assettax_X_7d", "heldwant_Y"] {
            XCTAssertTrue(prefixes.contains { id.hasPrefix($0) }, id)
        }
        for id in ["checkin_day_0", "daily_reminder", "backup_reminder"] {
            XCTAssertFalse(prefixes.contains { id.hasPrefix($0) }, id)
        }
    }
}
