import SwiftUI
import SwiftData

// MARK: - SwiftData Models

@Model
final class BankCard {
    var id: UUID
    var holderName: String
    var cardNumber: String
    var balance: Double
    var expireDate: String
    var gradientStart: String
    var gradientEnd: String
    var sortOrder: Int

    @Relationship(deleteRule: .cascade)
    var transactions: [TxRecord] = []

    init(holderName: String, cardNumber: String, balance: Double,
         expireDate: String, gradientStart: String, gradientEnd: String, sortOrder: Int) {
        self.id = UUID()
        self.holderName = holderName
        self.cardNumber = cardNumber
        self.balance = balance
        self.expireDate = expireDate
        self.gradientStart = gradientStart
        self.gradientEnd = gradientEnd
        self.sortOrder = sortOrder
    }
}

@Model
final class TxRecord {
    var id: UUID
    var name: String
    var date: Date
    var amount: Double
    var type: String
    var icon: String
    var iconBgHex: String
    var categoryRaw: String
    var currency: String  // "USD" or "IDR"
    var notes: String

    var category: TxCategory {
        get { TxCategory(rawValue: categoryRaw) ?? .other }
        set { categoryRaw = newValue.rawValue }
    }

    init(name: String, date: Date, amount: Double, type: String,
         icon: String, iconBgHex: String, category: TxCategory,
         currency: String = "USD", notes: String = "") {
        self.id = UUID()
        self.name = name
        self.date = date
        self.amount = amount
        self.type = type
        self.icon = icon
        self.iconBgHex = iconBgHex
        self.categoryRaw = category.rawValue
        self.currency = currency
        self.notes = notes
    }
}

enum TxCategory: String, CaseIterable, Codable {
    case shopping    = "Shopping"
    case food        = "Food & Drinks"
    case travel      = "Travel"
    case transfer    = "Transfer"
    case debtPayment = "Debt Payment"
    case other       = "Other"

    var icon: String {
        switch self {
        case .shopping:    return "bag"
        case .food:        return "fork.knife"
        case .travel:      return "airplane"
        case .transfer:    return "dollarsign.circle"
        case .debtPayment: return "creditcard.trianglebadge.exclamationmark"
        case .other:       return "ellipsis"
        }
    }

    var color: Color {
        switch self {
        case .shopping:    return AppTheme.orange
        case .food:        return Color(hex: "#FF6B6B")
        case .travel:      return AppTheme.blue
        case .transfer:    return AppTheme.accent
        case .debtPayment: return AppTheme.red
        case .other:       return AppTheme.textSecondary
        }
    }

    var iconBg: String {
        switch self {
        case .shopping:    return "#FF9900"
        case .food:        return "#FF6B6B"
        case .travel:      return "#38BDF8"
        case .transfer:    return "#5EFFC8"
        case .debtPayment: return "#FF5B5B"
        case .other:       return "#5B6F6B"
        }
    }
}

// MARK: - Currency Manager

@Observable
final class CurrencyManager {
    static let shared = CurrencyManager()
    private init() { loadRate() }

    var usdToIdr: Double = 16200.0  // fallback rate
    var isLoading = false
    var lastUpdated: Date? = nil

    func loadRate() {
        if let saved = UserDefaults.standard.object(forKey: "usd_idr_rate") as? Double,
           let date = UserDefaults.standard.object(forKey: "usd_idr_date") as? Date,
           Date().timeIntervalSince(date) < 3600 {
            usdToIdr = saved
            lastUpdated = date
            return
        }
        fetchRate()
    }

    func fetchRate() {
        isLoading = true
        // Free exchange rate API (no key needed)
        guard let url = URL(string: "https://open.er-api.com/v6/latest/USD") else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            DispatchQueue.main.async {
                self.isLoading = false
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let rates = json["rates"] as? [String: Any],
                      let idr = rates["IDR"] as? Double else { return }
                self.usdToIdr = idr
                self.lastUpdated = Date()
                UserDefaults.standard.set(idr, forKey: "usd_idr_rate")
                UserDefaults.standard.set(Date(), forKey: "usd_idr_date")
            }
        }.resume()
    }

    func convert(_ amount: Double, from: String, to: String) -> Double {
        if from == to { return amount }
        if from == "USD" && to == "IDR" { return amount * usdToIdr }
        if from == "IDR" && to == "USD" { return amount / usdToIdr }
        return amount
    }

    func formatted(_ amount: Double, currency: String) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        if currency == "IDR" {
            f.maximumFractionDigits = 0
            return "IDR \(f.string(from: NSNumber(value: amount)) ?? "")"
        } else {
            f.minimumFractionDigits = 2
            f.maximumFractionDigits = 2
            return "$\(f.string(from: NSNumber(value: amount)) ?? "")"
        }
    }

    var rateLabel: String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        f.groupingSeparator = ","
        let idrStr = f.string(from: NSNumber(value: usdToIdr)) ?? ""
        return "1 USD = IDR \(idrStr)"
    }
}

// MARK: - Theme

struct AppTheme {
    static let bg            = Color(hex: "#1A1F1E")
    static let cardDark      = Color(hex: "#222827")
    static let cardMid       = Color(hex: "#2A3330")
    static let accent        = Color(hex: "#5EFFC8")
    static let textPrimary   = Color.white
    static let textSecondary = Color(hex: "#8A9693")
    static let red           = Color(hex: "#FF5B5B")
    static let green         = Color(hex: "#5EFFC8")
    static let purple        = Color(hex: "#A78BFA")
    static let orange        = Color(hex: "#FB923C")
    static let blue          = Color(hex: "#38BDF8")
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:  (a,r,g,b) = (255,(int>>8)*17,(int>>4 & 0xF)*17,(int & 0xF)*17)
        case 6:  (a,r,g,b) = (255,int>>16,int>>8 & 0xFF,int & 0xFF)
        case 8:  (a,r,g,b) = (int>>24,int>>16 & 0xFF,int>>8 & 0xFF,int & 0xFF)
        default: (a,r,g,b) = (255,0,0,0)
        }
        self.init(.sRGB, red: Double(r)/255, green: Double(g)/255,
                  blue: Double(b)/255, opacity: Double(a)/255)
    }
}

// MARK: - Haptic Manager

final class HapticManager {
    static let shared = HapticManager()
    private init() {}

    private let impactMed  = UIImpactFeedbackGenerator(style: .medium)
    private let light      = UIImpactFeedbackGenerator(style: .light)
    private let rigid      = UIImpactFeedbackGenerator(style: .rigid)
    private let selection  = UISelectionFeedbackGenerator()
    private let notif      = UINotificationFeedbackGenerator()

    func prepare() {
        impactMed.prepare(); light.prepare()
        rigid.prepare(); selection.prepare(); notif.prepare()
    }

    func tap()           { light.impactOccurred() }
    func mediumImpact()  { impactMed.impactOccurred() }
    func rigidImpact()   { rigid.impactOccurred() }
    func select()        { selection.selectionChanged() }
    func success()       { notif.notificationOccurred(.success) }
    func warning()       { notif.notificationOccurred(.warning) }
    func error()         { notif.notificationOccurred(.error) }
}

// MARK: - App ViewModel

@Observable
final class AppViewModel {
    var cards: [BankCard] = []
    var selectedCardIndex: Int = 0
    var activeTab: AppTab = .home
    var isLoaded: Bool = false
    var showCardManager: Bool = false

    var selectedCard: BankCard? { cards.isEmpty ? nil : cards[selectedCardIndex] }

    var recentTransactions: [TxRecord] {
        cards.flatMap { $0.transactions }.sorted { $0.date > $1.date }
    }

    var totalBalance: Double { cards.reduce(0) { $0 + $1.balance } }

    func selectTab(_ tab: AppTab) {
        HapticManager.shared.select()
        activeTab = tab
    }

    func selectCard(_ index: Int) {
        guard index != selectedCardIndex else { return }
        HapticManager.shared.tap()
        selectedCardIndex = index
    }
}

// MARK: - Stats ViewModel

@Observable
final class StatsViewModel {
    var selectedStatTab: StatTab = .expenses
    var chartProgress: Double = 0
    var selectedSliceIndex: Int? = nil
    var filterPeriod: String = "This month"

    var categories: [SpendCategory] = [
        SpendCategory(name: "Shopping",  amount: 4200, color: AppTheme.orange),
        SpendCategory(name: "Education", amount: 2100, color: AppTheme.purple),
        SpendCategory(name: "Travel",    amount: 1800, color: AppTheme.blue),
        SpendCategory(name: "Transfer",  amount: 2400, color: AppTheme.accent),
        SpendCategory(name: "Other",     amount: 756,  color: AppTheme.textSecondary)
    ]

    var total: Double { categories.reduce(0) { $0 + $1.amount } }

    func animateIn() {
        chartProgress = 0
        withAnimation(.spring(response: 1.1, dampingFraction: 0.75).delay(0.2)) {
            chartProgress = 1
        }
    }

    func selectSlice(_ index: Int?) {
        HapticManager.shared.tap()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            selectedSliceIndex = (selectedSliceIndex == index) ? nil : index
        }
    }

    func switchTab(_ tab: StatTab) {
        HapticManager.shared.select()
        selectedStatTab = tab
        animateIn()
    }
}

struct SpendCategory: Identifiable {
    let id = UUID()
    let name: String
    let amount: Double
    let color: Color
}

enum StatTab: String, CaseIterable {
    case income = "Income"
    case expenses = "Expenses"
}

// MARK: - AppTab

enum AppTab: Int, CaseIterable {
    case home = 0, stats, add, debt, profile

    var icon: String {
        switch self {
        case .home:    return "house.fill"
        case .stats:   return "chart.bar.fill"
        case .add:     return "plus"
        case .debt:    return "creditcard.trianglebadge.exclamationmark"
        case .profile: return "person"
        }
    }

    var label: String {
        switch self {
        case .home:    return "Home"
        case .stats:   return "Stats"
        case .add:     return ""
        case .debt:    return "Debt"
        case .profile: return "Profile"
        }
    }
}

// MARK: - Seed Data

struct DataSeeder {
    // No sample data — users start fresh and add their own cards
    static func seedIfNeeded(context: ModelContext) {}
}
