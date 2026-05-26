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
    var currency: String        // Card's native currency — set at creation, never changes
    var isDigitalWallet: Bool   // true = e-wallet, no card number needed
    var walletProvider: String  // e.g. "GoPay", "OVO", "DANA", ""
    var phoneNumber: String     // for digital wallets
    var isHidden: Bool          // per-card hide/show for number & balance

    @Relationship(deleteRule: .cascade)
    var transactions: [TxRecord] = []

    init(holderName: String, cardNumber: String, balance: Double,
         expireDate: String, gradientStart: String, gradientEnd: String,
         sortOrder: Int,
         currency: String = CurrencyManager.shared.preferredCurrency,
         isDigitalWallet: Bool = false,
         walletProvider: String = "",
         phoneNumber: String = "",
         isHidden: Bool = false) {
        self.id = UUID()
        self.holderName = holderName
        self.cardNumber = cardNumber
        self.balance = balance
        self.expireDate = expireDate
        self.gradientStart = gradientStart
        self.gradientEnd = gradientEnd
        self.sortOrder = sortOrder
        self.currency = currency
        self.isDigitalWallet = isDigitalWallet
        self.walletProvider = walletProvider
        self.phoneNumber = phoneNumber
        self.isHidden = isHidden
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
    
    /// UUID string of the linked DebtRecord if this tx is a debt payment.
    /// Used to compute debt balance dynamically — when this tx is deleted,
    /// the debt's effective balance updates automatically. Default value
    /// keeps the property optional for backward compatibility with existing
    /// data. Not optional because SwiftData migrations are simpler this way.
    var linkedDebtID: String = ""

    /// Transaction subtype — distinguishes normal expense/income from
    /// refunds (reversing a prior expense, NOT new income) and inter-account
    /// transfers (shouldn't count as income OR expense for budgeting math).
    /// Stored as rawValue string so SwiftData migration is non-destructive
    /// for old rows that don't have this field — defaults to "normal".
    var subtype: String = "normal"

    var category: TxCategory {
        get { TxCategory(rawValue: categoryRaw) ?? .other }
        set { categoryRaw = newValue.rawValue }
    }

    /// Typed accessor for `subtype`. Falls back to `.normal` when the stored
    /// string is unrecognized so corrupt or future-version data degrades
    /// gracefully into "treat as normal".
    var txSubtype: TxSubtype {
        get { TxSubtype(rawValue: subtype) ?? .normal }
        set { subtype = newValue.rawValue }
    }

    init(name: String, date: Date, amount: Double, type: String,
         icon: String, iconBgHex: String, category: TxCategory,
         currency: String = "USD", notes: String = "",
         linkedDebtID: String = "",
         subtype: TxSubtype = .normal) {
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
        self.linkedDebtID = linkedDebtID
        self.subtype = subtype.rawValue
    }
}

// MARK: - TxRecord Display Helpers
// Translates stable keys stored in the DB at render time. Also gracefully
// handles legacy data where `type`/`notes` were stored as raw English strings
// before the stable-key migration (e.g. "Income", "Debt Payment", "Auto-credited on payday").
//
// Rule: data in SwiftData stays in a stable, language-independent form.
// Translation happens ONLY at display time. Never store loc() results in the DB —
// that freezes the language at creation time and breaks when users switch locale.

extension TxRecord {

    /// Localized display string for `type`. Recognizes both new stable-key format
    /// (`tx.type.purchase`, `tx.type.income`, `tx.type.debt_payment`) and legacy
    /// raw values ("Purchase", "Income", "Debt Payment") still present in old rows.
    var displayType: String {
        let key: String
        switch type {
        // New stable-key format — pass through to loc()
        case "tx.type.purchase", "tx.type.income", "tx.type.debt_payment":
            key = type
        // Legacy raw values — map to the new key
        case "Purchase":     key = "tx.type.purchase"
        case "Income":       key = "tx.type.income"
        case "Debt Payment": key = "tx.type.debt_payment"
        // Legacy raw key that was accidentally stored (the bug this fix closes)
        case "debt.payment_type_name": key = "tx.type.debt_payment"
        // Anything else → user-entered or unknown → display as-is
        default: return type
        }
        return loc(key)
    }

    /// Localized display string for `notes`. Three cases:
    /// 1. Pre-formatted string with placeholder args already substituted (conversion note) → display as-is.
    /// 2. Stable key stored at creation time (tx.note.*) → translate via loc().
    /// 3. User-entered free-form note → display as-is.
    var displayNotes: String {
        guard !notes.isEmpty else { return "" }
        // A stored stable key looks like "tx.note.xxx" — no spaces, starts with tx.note.
        // Legacy rows may have "Auto-credited on payday" or the raw key. Handle both.
        switch notes {
        case "Auto-credited on payday":
            return loc("tx.note.salary_auto")
        case "tx.note.debt_payment_auto",
             "tx.note.salary_auto":
            return loc(notes)
        default:
            // If it looks like a dotted key without spaces, try loc() as a last resort.
            // loc() falls back to the key itself if unknown, which is the current broken
            // behavior — but at least new keys added to the dict start working immediately.
            if notes.hasPrefix("tx.note.") && !notes.contains(" ") {
                return loc(notes)
            }
            return notes
        }
    }

    /// Locale-aware formatted date that follows the in-app language, not the iOS
    /// system locale. Replaces `tx.date.formatted(...)` which uses Locale.current.
    var displayDate: String {
        let f = DateFormatter()
        f.locale    = LanguageManager.shared.currentLocale
        f.dateStyle = .full
        f.timeStyle = .short
        return f.string(from: date)
    }
}

// MARK: - TxSubtype
// Distinguishes how a transaction should be treated in budget calculations.
// `.normal` is the implicit default (every existing tx). `.refund` reverses
// an earlier expense without counting as new income. `.transfer` is movement
// between user's own accounts — irrelevant to spend/save analysis.

enum TxSubtype: String, CaseIterable, Codable {
    case normal   = "normal"    // standard income or expense
    case refund   = "refund"    // expense reversal (e.g., merchant refund)
    case transfer = "transfer"  // inter-account move; ignore in budget math

    var displayLabel: String {
        switch self {
        case .normal:   return loc("tx.subtype.normal")
        case .refund:   return loc("tx.subtype.refund")
        case .transfer: return loc("tx.subtype.transfer")
        }
    }

    var icon: String {
        switch self {
        case .normal:   return "circle.fill"
        case .refund:   return "arrow.uturn.backward.circle.fill"
        case .transfer: return "arrow.left.arrow.right.circle.fill"
        }
    }
}

// MARK: - TxCategory
// rawValue stays as the canonical English string (used as storage key + switch key),
// displayLabel (defined below as extension) is what the UI shows.

enum TxCategory: String, CaseIterable, Codable {
    // ── Expense categories ──
    case shopping    = "Shopping"
    case food        = "Food & Drinks"
    case travel      = "Travel"
    case bills       = "Bills"
    case transport   = "Transport"
    case health      = "Health"
    case other       = "Other"
    // ── Income categories ──
    case salary      = "Salary"
    case freelance   = "Freelance"
    case business    = "Business"
    case investment  = "Investment"
    case bonus       = "Bonus"
    case gift        = "Gift"
    case incomeOther = "Other Income"
    // ── Debt categories ──
    case debtPayment = "Debt Payment"

    var icon: String {
        switch self {
        case .shopping:    return "bag.fill"
        case .food:        return "fork.knife"
        case .travel:      return "airplane"
        case .bills:       return "bolt.fill"
        case .transport:   return "car.fill"
        case .health:      return "heart.fill"
        case .other:       return "ellipsis.circle.fill"
        case .salary:      return "banknote.fill"
        case .freelance:   return "laptopcomputer"
        case .business:    return "briefcase.fill"
        case .investment:  return "chart.line.uptrend.xyaxis"
        case .bonus:       return "star.fill"
        case .gift:        return "gift.fill"
        case .incomeOther: return "ellipsis.circle.fill"
        case .debtPayment: return "creditcard.fill"
        }
    }

    var color: Color {
        switch self {
        case .shopping:    return AppTheme.orange
        case .food:        return Color(hex: "#FF6B6B")
        case .travel:      return AppTheme.blue
        case .bills:       return Color(hex: "#F59E0B")
        case .transport:   return Color(hex: "#6366F1")
        case .health:      return Color(hex: "#EC4899")
        case .other:       return AppTheme.textSecondary
        case .salary:      return AppTheme.accent
        case .freelance:   return Color(hex: "#38BDF8")
        case .business:    return Color(hex: "#A78BFA")
        case .investment:  return Color(hex: "#34D399")
        case .bonus:       return Color(hex: "#FBBF24")
        case .gift:        return Color(hex: "#F87171")
        case .incomeOther: return AppTheme.textSecondary
        case .debtPayment: return Color(hex: "#FF6B6B")
        }
    }

    var iconBg: String {
        switch self {
        case .shopping:    return "#FF9900"
        case .food:        return "#FF6B6B"
        case .travel:      return "#38BDF8"
        case .bills:       return "#F59E0B"
        case .transport:   return "#6366F1"
        case .health:      return "#EC4899"
        case .other:       return "#5B6F6B"
        case .salary:      return "#1D9E75"
        case .freelance:   return "#0EA5E9"
        case .business:    return "#7C3AED"
        case .investment:  return "#059669"
        case .bonus:       return "#D97706"
        case .gift:        return "#DC2626"
        case .incomeOther: return "#5B6F6B"
        case .debtPayment: return "#FF4444"
        }
    }
}

// MARK: - TxCategory Localized Label

extension TxCategory {
    /// Localized label for UI display. The rawValue is the stable key used for
    /// storage and code logic — never show it directly in the UI.
    var displayLabel: String {
        switch self {
        case .shopping:    return loc("category.shopping")
        case .food:        return loc("category.food")
        case .travel:      return loc("category.travel")
        case .bills:       return loc("category.bills")
        case .transport:   return loc("category.transport")
        case .health:      return loc("category.health")
        case .other:       return loc("category.other")
        case .salary:      return loc("category.salary")
        case .freelance:   return loc("category.freelance")
        case .business:    return loc("category.business")
        case .investment:  return loc("category.investment")
        case .bonus:       return loc("category.bonus")
        case .gift:        return loc("category.gift")
        case .incomeOther: return loc("category.income_other")
        case .debtPayment: return loc("category.debt_payment")
        }
    }

    /// Short localized label for compact UI (filter bar, pills with limited width).
    /// Shorter than displayLabel for categories with long names.
    var shortLabel: String {
        switch self {
        case .food:        return loc("category.short.food")
        case .investment:  return loc("category.short.investment")
        case .debtPayment: return loc("category.short.debt")
        case .incomeOther: return loc("category.short.income_other")
        // All others are short enough — reuse displayLabel
        default:           return displayLabel
        }
    }
}

// MARK: - Currency Manager

@Observable
final class CurrencyManager {
    static let shared = CurrencyManager()

    private static let cacheRatesKey     = "exchange_rates_v2"
    private static let cacheDateKey      = "exchange_rates_date_v2"
    private static let cacheMaxAge: TimeInterval = 3600          // 1 jam
    private static let autoRefreshInterval: TimeInterval = 1800  // 30 menit
    private static let apiURL = "https://open.er-api.com/v6/latest/USD"

    // Semua mata uang yang didukung di seluruh aplikasi.
    // Tambah di sini saja — fetch & convert langsung bekerja.
    static let supportedCurrencies: [(code: String, name: String, symbol: String, flag: String)] = [
        ("IDR", "Rupiah Indonesia",    "Rp",  "🇮🇩"),
        ("USD", "US Dollar",           "$",   "🇺🇸"),
        ("EUR", "Euro",                "€",   "🇪🇺"),
        ("SGD", "Singapore Dollar",    "S$",  "🇸🇬"),
        ("MYR", "Malaysian Ringgit",   "RM",  "🇲🇾"),
        ("JPY", "Japanese Yen",        "¥",   "🇯🇵"),
        ("GBP", "British Pound",       "£",   "🇬🇧"),
        ("AUD", "Australian Dollar",   "A$",  "🇦🇺"),
        ("CNY", "Chinese Yuan",        "¥",   "🇨🇳"),
        ("KRW", "Korean Won",          "₩",   "🇰🇷"),
        ("SAR", "Saudi Riyal",         "﷼",   "🇸🇦"),
        ("THB", "Thai Baht",           "฿",   "🇹🇭"),
    ]

    // Set kode currency — digunakan saat fetch agar tidak bergantung
    // pada keys yang sudah ada di `rates` (itulah bug lama).
    private static let wantedCodes: Set<String> =
        Set(supportedCurrencies.map(\.code))

    static func symbol(for currency: String) -> String {
        supportedCurrencies.first(where: { $0.code == currency })?.symbol ?? currency
    }

    static func flag(for currency: String) -> String {
        supportedCurrencies.first(where: { $0.code == currency })?.flag ?? ""
    }

    // ── State ──────────────────────────────────────────────────────────

    var preferredCurrency: String {
        didSet { UserDefaults.standard.set(preferredCurrency, forKey: "preferred_currency") }
    }

    /// Kurs live, basis USD. USD sendiri selalu 1.0.
    /// Fallback offline berasal dari kurs yang terakhir tersimpan di cache.
    var rates: [String: Double] = [
        "USD": 1.0,
        "IDR": 16200.0,
        "EUR": 0.93,
        "SGD": 1.35,
        "MYR": 4.77,
        "JPY": 153.5,
        "GBP": 0.79,
        "AUD": 1.54,
        "CNY": 7.24,
        "KRW": 1360.0,
        "SAR": 3.75,
        "THB": 36.5,
    ]

    var isLoading   = false
    var lastUpdated: Date? = nil
    var lastError:   String? = nil

    var usdToIdr: Double { rates["IDR"] ?? 16200.0 }

    // ── Timer auto-refresh ─────────────────────────────────────────────
    private var refreshTimer: Timer?

    private init() {
        preferredCurrency = UserDefaults.standard.string(forKey: "preferred_currency") ?? "IDR"
        loadCachedRates()
        startAutoRefresh()
    }

    deinit { refreshTimer?.invalidate() }

    private func startAutoRefresh() {
        refreshTimer = Timer.scheduledTimer(
            withTimeInterval: Self.autoRefreshInterval,
            repeats: true
        ) { [weak self] _ in
            self?.fetchRate()
        }
        refreshTimer?.tolerance = 60  // sistem boleh menunda ±60 detik untuk efisiensi baterai
    }

    // ── Cache ──────────────────────────────────────────────────────────

    private func loadCachedRates() {
        guard
            let saved = UserDefaults.standard.object(forKey: Self.cacheRatesKey) as? [String: Double],
            let date  = UserDefaults.standard.object(forKey: Self.cacheDateKey)  as? Date
        else {
            // Tidak ada cache — langsung fetch
            fetchRate()
            return
        }
        // Gabungkan cache dengan fallback agar semua currency tersedia
        rates       = rates.merging(saved) { _, cached in cached }
        lastUpdated = date
        print("[DiPo] Currency: loaded cache (\(saved.count) rates) dari \(date)")

        // Cache basi → fetch di background, tapi rate lama tetap dipakai
        if Date().timeIntervalSince(date) >= Self.cacheMaxAge {
            fetchRate()
        }
    }

    private func saveCache(_ newRates: [String: Double]) {
        UserDefaults.standard.set(newRates,  forKey: Self.cacheRatesKey)
        UserDefaults.standard.set(Date(),    forKey: Self.cacheDateKey)
        // Hapus kunci lama agar tidak membingungkan
        UserDefaults.standard.removeObject(forKey: "exchange_rates")
        UserDefaults.standard.removeObject(forKey: "usd_idr_date")
    }

    // ── Fetch ──────────────────────────────────────────────────────────

    /// Ambil kurs terbaru dari open.er-api.com.
    /// Bisa dipanggil manual (pull-to-refresh) maupun otomatis oleh timer.
    func fetchRate(forceRefresh: Bool = false) {
        // Jika cache masih segar dan bukan force, skip
        if !forceRefresh,
           let date = lastUpdated,
           Date().timeIntervalSince(date) < Self.cacheMaxAge {
            print("[DiPo] Currency: cache segar, skip fetch")
            return
        }

        Task { @MainActor in
            isLoading = true
            lastError = nil
            defer { isLoading = false }

            do {
                guard let url = URL(string: Self.apiURL) else { return }
                let (data, response) = try await URLSession.shared.data(from: url)

                // Validasi HTTP
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    throw URLError(.badServerResponse)
                }

                guard
                    let json     = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let allRates = json["rates"] as? [String: Any]
                else { throw URLError(.cannotParseResponse) }

                // ✅ FIX: iterasi wantedCodes, BUKAN `rates` yang sudah ada.
                //    Bug lama: `for (code, _) in rates` → hanya dapat IDR karena
                //    `rates` awalnya cuma punya ["IDR": 16200] sehingga EUR, SGD, dll
                //    tidak pernah diambil dari respons API.
                var newRates: [String: Double] = ["USD": 1.0]
                for code in Self.wantedCodes where code != "USD" {
                    if let r = allRates[code] as? Double { newRates[code] = r }
                }

                rates       = rates.merging(newRates) { _, live in live }
                lastUpdated = Date()
                lastError   = nil
                saveCache(newRates)

                print("[DiPo] Currency: ✅ fetch OK — \(newRates.count) rates, USD→IDR: \(usdToIdr)")

            } catch {
                // Tetap pakai rate terakhir yang ada
                lastError = error.localizedDescription
                print("[DiPo] Currency: ❌ fetch gagal — \(error.localizedDescription)")
            }
        }
    }

    // ── Conversion ─────────────────────────────────────────────────────

    func convert(_ amount: Double, from: String, to: String) -> Double {
        guard from != to else { return amount }
        // Semua konversi lewat USD sebagai pivot
        let inUSD = from == "USD" ? amount : amount / (rates[from] ?? 1.0)
        return to  == "USD" ? inUSD : inUSD * (rates[to] ?? 1.0)
    }

    func toPreferred(_ amount: Double, from: String) -> Double {
        convert(amount, from: from, to: preferredCurrency)
    }

    // ── Formatting ─────────────────────────────────────────────────────

    func formatted(_ amount: Double, currency: String) -> String {
        let f   = NumberFormatter()
        f.numberStyle          = .decimal
        f.usesGroupingSeparator = true
        f.groupingSize         = 3
        let cur = currency.uppercased()
        // Konvensi titik-sebagai-pemisah-ribuan untuk IDR, EUR, dll.
        let dotForGrouping: Set<String> = ["IDR","EUR","BRL","VND","DKK","ISK","NOK","SEK","TRY"]
        if dotForGrouping.contains(cur) {
            f.groupingSeparator = "."
            f.decimalSeparator  = ","
        } else {
            f.groupingSeparator = ","
            f.decimalSeparator  = "."
        }
        let sym       = Self.symbol(for: currency)
        let noDecimals: Set<String> = ["IDR","JPY","KRW","VND"]
        if noDecimals.contains(cur) {
            f.maximumFractionDigits = 0
            f.minimumFractionDigits = 0
            return "\(sym) \(f.string(from: NSNumber(value: amount)) ?? "0")"
        } else {
            f.minimumFractionDigits = 2
            f.maximumFractionDigits = 2
            return "\(sym)\(f.string(from: NSNumber(value: amount)) ?? "0.00")"
        }
    }

    // ── Rate Label ─────────────────────────────────────────────────────

    /// Label ringkas untuk ditampilkan di UI, misal di panel Konversi Cerdas.
    var rateLabel: String {
        let f = NumberFormatter()
        f.numberStyle           = .decimal
        f.usesGroupingSeparator = true
        f.groupingSeparator     = "."
        f.groupingSize          = 3
        f.maximumFractionDigits = 0
        let idrStr = f.string(from: NSNumber(value: usdToIdr)) ?? ""
        guard let updated = lastUpdated else {
            return "1 USD = IDR \(idrStr)"
        }
        return "1 USD = IDR \(idrStr) · \(relativeTimeString(from: updated))"
    }

    /// Label status untuk ditampilkan saat fetch gagal.
    var statusLabel: String {
        if isLoading { return loc("currency.fetching") }
        if let err = lastError { return "⚠️ \(err)" }
        guard let updated = lastUpdated else { return "" }
        return "🟢 \(loc("currency.live")) · \(relativeTimeString(from: updated))"
    }

    private func relativeTimeString(from date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60  { return loc("currency.just_now") }
        if seconds < 3600 {
            let m = seconds / 60
            return "\(m) \(loc("currency.minutes_ago"))"
        }
        let h = seconds / 3600
        return "\(h) \(loc("currency.hours_ago"))"
    }
}

// MARK: - Per-Card Budget Configuration
//
// Stores Smart Budget allocation ratios PER card. The user can set different
// strategies for different cards — e.g. a salary card uses 50/30/20 (Classic)
// while a side-business card uses 40/30/30 (Aggressive). Without a config row,
// a card falls back to the global defaults in SmartBudgetManager.
//
// We use a separate @Model rather than embedding fields in BankCard so that
// adding/removing budget features doesn't trigger card schema migrations,
// and so cards without budget tracking stay clean.

@Model
final class CardBudgetConfig {
    /// Foreign key — `BankCard.id.uuidString`. Not a relationship because the
    /// card may be deleted and we want config to follow card-by-id semantics.
    @Attribute(.unique) var cardID: String
    var dailyRatio: Double
    var lifestyleRatio: Double
    var investDebtRatio: Double
    var updatedAt: Date

    init(cardID: String,
         dailyRatio: Double = 0.50,
         lifestyleRatio: Double = 0.30,
         investDebtRatio: Double = 0.20) {
        self.cardID = cardID
        self.dailyRatio = dailyRatio
        self.lifestyleRatio = lifestyleRatio
        self.investDebtRatio = investDebtRatio
        self.updatedAt = .now
    }
}

// MARK: - Theme


struct DataSeeder {
    static func seedIfNeeded(context: ModelContext) {}
}
