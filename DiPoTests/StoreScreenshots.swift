import XCTest
import SwiftUI
import SwiftData
@testable import DiPo

/// Pictures of real DiPo screens for dipo.info, drawn by the app's own views
/// over a demo account. Not a test of behaviour: it runs only when
/// `DIPO_SCREENSHOTS_DIR` is set, which `.github/workflows/screenshots.yml`
/// does (as `TEST_RUNNER_DIPO_SCREENSHOTS_DIR`). Everywhere else it skips.
///
/// The demo person is the site's reader: paid Rp 5,5 juta on the 25th into
/// BRI, a motorbike on instalments, a little gold and a money-market fund.
/// Nothing here is anyone's real data. Prices are set by hand so nothing is
/// fetched while the screens are drawn.
@MainActor
final class StoreScreenshots: XCTestCase {

    private var outDir: URL!

    override func setUpWithError() throws {
        guard let dir = ProcessInfo.processInfo.environment["DIPO_SCREENSHOTS_DIR"], !dir.isEmpty else {
            throw XCTSkip("Screenshots are drawn only by .github/workflows/screenshots.yml")
        }
        outDir = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    }

    func testStoreScreens() throws {
        CurrencyManager.shared.preferredCurrency = "IDR"
        for language in [LanguageManager.Language.indonesian, .english] {
            LanguageManager.shared.current = language
            let container = try DemoAccount.make()
            try shoot(InvestmentView(), "investasi", language, container)
            try shoot(AssetsView(), "aset", language, container)
            try shoot(SmartRecommendationView(), "rekomendasi", language, container)
        }
    }

    // MARK: Drawing

    /// The view, full screen in the app's own window scene (so the safe areas
    /// are a real iPhone's), dark, after its appear work has settled.
    private func shoot<V: View>(_ view: V, _ name: String, _ language: LanguageManager.Language,
                                _ container: ModelContainer) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let size = scene.screen.bounds.size
        let host = UIHostingController(rootView: view
            .modelContainer(container)
            .preferredColorScheme(.dark)
            .environment(\.locale, Locale(identifier: language == .indonesian ? "id_ID" : "en_US")))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        // onAppear and .task run, a count-up or two finishes, layout settles.
        RunLoop.main.run(until: Date().addingTimeInterval(3))
        host.view.layoutIfNeeded()

        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            host.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
        }
        let url = outDir.appendingPathComponent("\(name)-\(language.rawValue).png")
        try XCTUnwrap(image.pngData()).write(to: url)
        print("[screenshots] wrote \(url.lastPathComponent) \(Int(size.width))x\(Int(size.height))")
    }
}

// MARK: - The demo account

@MainActor
private enum DemoAccount {

    static func make() throws -> ModelContainer {
        let schema = Schema(versionedSchema: DiPoSchemaCurrent.self)
        let container = try ModelContainer(for: schema,
                                           configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        let context = container.mainContext
        let cal = Calendar.current
        let now = Date()

        // The account money comes into, and the salary that lands there.
        let bri = BankCard(holderName: "BRI", cardNumber: "0123456789013345", balance: 2_870_000,
                           expireDate: "11/29", gradientStart: "#0A3D91", gradientEnd: "#1565C0",
                           sortOrder: 0, currency: "IDR")
        context.insert(bri)
        MainCard.set(bri)
        context.insert(SalarySchedule(label: "Gaji", amount: 5_500_000, dayOfMonth: 25,
                                      currency: "IDR", cardID: bri.id))

        func add(_ name: String, _ amount: Double, _ category: TxCategory, _ date: Date) {
            let t = TxRecord(name: name, date: date, amount: amount,
                             type: amount < 0 ? "tx.type.purchase" : "tx.type.income",
                             icon: String(name.prefix(2)).uppercased(), iconBgHex: category.iconBg,
                             category: category, currency: "IDR", subtype: .normal)
            context.insert(t)
            bri.transactions.append(t)
        }
        func day(monthsAgo: Int, _ d: Int) -> Date {
            let base = cal.date(byAdding: .month, value: -monthsAgo, to: now) ?? now
            var c = cal.dateComponents([.year, .month], from: base)
            c.day = d; c.hour = 12
            return min(cal.date(from: c) ?? now, now)
        }

        // Three months of an ordinary pay cycle.
        for m in 0...3 {
            add("Gaji", 5_500_000, .salary, day(monthsAgo: m, 25))
            add("Kontrakan", -1_200_000, .commitment, day(monthsAgo: m, 26))
            add("Cicilan motor", -780_000, .debtPayment, day(monthsAgo: m, 28))
            add("Token listrik", -150_000, .bills, day(monthsAgo: m, 2))
            add("Pulsa & data", -100_000, .bills, day(monthsAgo: m, 3))
            add("Belanja bulanan", -650_000, .shopping, day(monthsAgo: m, 27))
            for (i, d) in [1, 4, 7, 10, 13, 16, 19, 22].enumerated() {
                add(i % 2 == 0 ? "Warung makan" : "Kopi", i % 2 == 0 ? -38_000 : -18_000, .food, day(monthsAgo: m, d))
                add("Bensin", -30_000, .transport, day(monthsAgo: m, d))
            }
            add("Kiriman orang tua", -500_000, .commitment, day(monthsAgo: m, 26))
        }

        // Saving and owing.
        let emergency = SavingsGoal(name: "Dana darurat", targetAmount: 15_000_000, currency: "IDR")
        emergency.savedAmount = 4_200_000
        context.insert(emergency)
        context.insert(DebtRecord(name: "Cicilan motor", totalAmount: 18_000_000, currentBalance: 9_360_000,
                                  minimumPayment: 780_000, annualInterestRate: 9, dueDayOfMonth: 28, currency: "IDR"))

        // A small portfolio, priced by hand.
        func holding(_ type: InvestmentType, _ name: String, symbol: String = "", price: Double, prev: Double,
                     order: Int, lots: [(monthsAgo: Int, units: Double, price: Double)]) {
            let h = InvestmentHolding(type: type, name: name, symbol: symbol, currency: "IDR",
                                      lastPrice: price, prevClose: prev, manualPrice: true, sortOrder: order)
            if type == .gold { h.setGoldSource(.manual) }
            context.insert(h)
            for lot in lots {
                let l = InvestmentLot(kind: .buy, date: day(monthsAgo: lot.monthsAgo, 26),
                                      units: lot.units, pricePerUnit: lot.price)
                context.insert(l)
                h.lots.append(l)
            }
            for step in stride(from: 0.94, through: 1.0, by: 0.01) { h.pushPrice(price * step) }
            h.pushPrice(price)
        }
        holding(.gold, "Emas Antam", price: 1_452_000, prev: 1_446_000, order: 0,
                lots: [(5, 5, 1_318_000), (2, 3, 1_401_000), (0, 2, 1_440_000)])
        holding(.mutualFund, "Reksa dana pasar uang", price: 1_871, prev: 1_870, order: 1,
                lots: [(4, 1_100, 1_820), (1, 500, 1_858)])
        holding(.stock, "Bank Rakyat Indonesia", symbol: "BBRI", price: 4_380, prev: 4_350, order: 2,
                lots: [(3, 300, 4_120)])
        holding(.deposit, "Deposito BRI", price: 1, prev: 1, order: 3,
                lots: [(6, 3_000_000, 1)])

        // What they own.
        func asset(_ kind: AssetKind, _ name: String, _ price: Double, yearsAgo: Int, order: Int) {
            let bought = cal.date(byAdding: .year, value: -yearsAgo, to: now) ?? now
            let a = PhysicalAsset(kind: kind, name: name, currency: "IDR", purchasePrice: price,
                                  purchaseDate: bought, sortOrder: order)
            context.insert(a)
        }
        asset(.motorcycle, "Honda Beat 2022", 18_500_000, yearsAgo: 3, order: 0)
        asset(.land, "Tanah kebun", 60_000_000, yearsAgo: 5, order: 1)
        asset(.electronics, "Samsung Galaxy A35", 5_000_000, yearsAgo: 1, order: 2)

        try context.save()
        return container
    }
}
