import Foundation

// MARK: - Which gold, and where its price comes from
//
// "Emas" covers things that are worth quite different amounts per gram: a
// Pegadaian savings balance, an Antam bar, a ring at 70%. Each rupiah gold
// holding says which it is, encoded in `symbol` (no stored-shape change):
//
//   "pegadaian"        Tabungan Emas Pegadaian / Tring (BRImo)
//   "antam" "ubs"      bars of the brands sold through Pegadaian and the
//   "galeri24"         big dealers — the ones people in the segment actually
//   "lotusarchi"       hold (see `GoldBrand`)
//   "perhiasan-70"     jewellery, by gold content in percent
//   ""                 priced by hand
//
// A gold the user names themselves (a dinar, a local shop's bar) has no feed
// of its own, so it never searches for one and never shows "not found": the
// user picks the price it follows — Antam's, as the most traded, by default.
//
// Every figure is the BUYBACK price — what the gold fetches if sold today —
// the same "lowest realistic value" rule the asset estimates follow.

enum GoldBrand: String, CaseIterable, Identifiable {
    case antam, ubs, galeri24, lotusarchi
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .antam:      return "Antam"
        case .ubs:        return "UBS"
        case .galeri24:   return "Galeri24"
        case .lotusarchi: return "Lotus Archi"
        }
    }
}

enum GoldSource: Hashable, Identifiable {
    case savings
    case bar(GoldBrand)
    /// Gold content in percent: 99 for 24K, 75 for 18K, 70 for "emas 70%".
    case jewelry(purity: Int)
    case manual

    var id: String { symbol.isEmpty ? "manual" : symbol }

    static let jewelryPrefix = "perhiasan-"

    /// Jewellery purities people ask for by name, highest first.
    static let purities: [Int] = [99, 91, 75, 70, 42, 37]

    var symbol: String {
        switch self {
        case .savings:              return GoldFeed.symbol
        case .bar(let b):           return b.rawValue
        case .jewelry(let purity):  return "\(Self.jewelryPrefix)\(purity)"
        case .manual:               return ""
        }
    }

    init(symbol raw: String) {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if s == GoldFeed.symbol {
            self = .savings
        } else if let b = GoldBrand(rawValue: s) {
            self = .bar(b)
        } else if s.hasPrefix(Self.jewelryPrefix),
                  let p = Int(s.dropFirst(Self.jewelryPrefix.count)), (1...100).contains(p) {
            self = .jewelry(purity: p)
        } else {
            self = .manual
        }
    }

    var displayName: String {
        switch self {
        case .savings:             return loc("gold.src.savings")
        case .bar(let b):          return b.displayName
        case .jewelry(let purity): return String(format: loc("gold.src.jewelry_n"), Self.purityLabel(purity))
        case .manual:              return loc("gold.src.manual")
        }
    }

    /// "24K (99%)", "18K (75%)", "70%", "Emas muda (37,5%)".
    static func purityLabel(_ p: Int) -> String {
        switch p {
        case 99: return "24K (99%)"
        case 91: return "22K (91,6%)"
        case 75: return "18K (75%)"
        case 70: return loc("gold.purity.70")
        case 42: return "10K (41,7%)"
        case 37: return loc("gold.purity.young")
        default: return "\(p)%"
        }
    }

    /// The feeds a refresh has to ask for to price this source.
    var requestSymbols: [String] {
        switch self {
        case .savings, .jewelry: return [GoldFeed.symbol]
        case .bar(let b):        return [b.rawValue, GoldFeed.symbol]
        case .manual:            return []
        }
    }
}

// MARK: - Pricing

enum GoldPricing {
    /// What a gold shop typically takes off jewellery it buys back, on top of
    /// pricing it by gold content: reported cuts run 7–25%. 15% sits on the
    /// cautious side of the middle, so a ring is never valued above what it fetches.
    static let jewelryCut = 0.15

    struct Priced: Equatable {
        let price: Double
        let prevClose: Double
        /// True when the brand's own price wasn't available and the figure is
        /// worked out from Pegadaian's.
        let estimated: Bool
    }

    /// The per-gram buyback price for `source`, from the quotes a refresh got
    /// back (keyed by feed symbol). Nil when nothing usable came back.
    static func price(for source: GoldSource,
                      quotes: [String: PriceService.Quote]) -> Priced? {
        let reference = quotes[GoldFeed.symbol]
        switch source {
        case .manual:
            return nil
        case .savings:
            return reference.map { Priced(price: $0.price, prevClose: $0.prevClose, estimated: false) }
        case .bar(let b):
            if let own = quotes[b.rawValue] {
                return Priced(price: own.price, prevClose: own.prevClose, estimated: false)
            }
            // A bar's buyback tracks the savings price closely; until the brand
            // has a feed, follow it and say so.
            return reference.map { Priced(price: $0.price, prevClose: $0.prevClose, estimated: true) }
        case .jewelry(let purity):
            guard let r = reference else { return nil }
            let factor = Double(purity) / 100 * (1 - jewelryCut)
            return Priced(price: r.price * factor, prevClose: r.prevClose * factor, estimated: true)
        }
    }

    private static let liveBrandsKey = "gold.liveFeeds"

    /// Feeds that answered the last refresh, so a bar can say whether its
    /// price is its brand's own or worked out from Pegadaian's.
    static func rememberLiveBrands(_ symbols: Set<String>) {
        guard !symbols.isEmpty else { return }   // a failed refresh changes nothing
        UserDefaults.standard.set(Array(symbols), forKey: liveBrandsKey)
    }

    /// Whether the price shown for `source` is an estimate.
    static func isEstimate(_ source: GoldSource) -> Bool {
        switch source {
        case .savings, .manual: return false
        case .jewelry:          return true
        case .bar(let b):
            let live = UserDefaults.standard.stringArray(forKey: liveBrandsKey) ?? []
            return !live.contains(b.rawValue)
        }
    }

    /// How far the buyback price still has to rise before selling would
    /// return what was paid — the spread a gold buyer starts behind by.
    /// Zero once it has.
    static func riseToBreakEven(avgCost: Double, buyback: Double) -> Double {
        guard avgCost > 0, buyback > 0, buyback < avgCost else { return 0 }
        return avgCost / buyback - 1
    }
}
