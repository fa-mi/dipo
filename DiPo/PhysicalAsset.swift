import SwiftUI
import SwiftData

// MARK: - Physical assets (Royal)
//
// What a household owns outside its accounts — the house, the land, the
// motorbike, the phone. For many DiPo users this is most of what they have,
// and leaving it out made net worth read as if it didn't exist.
//
// Valued by estimate: the purchase price moved by a yearly rate for the kind
// (land gains about 5% a year), or from a value the user set themselves when
// they know better. Never counted as emergency money — none of it turns into
// cash within days.
//
// Things that wear out lose most in the first year, then slowly. The first
// version used one flat rate (12% a year for vehicles), which put a 2017
// Honda Brio at Rp 50 jt while OLX listed the same car at Rp 107–125 jt.
// Vehicles in Indonesia hold their value far better than that, partly because
// new prices keep rising and pull used ones up with them.
//
// The rates are fitted to second-hand prices reported in 2025–2026 (OLX,
// detik oto, GridOto), as the share of the price new:
//   Honda BeAT     1 yr ≈ 90%   3 yrs 74–80%   5 yrs 66–71%
//   Vario 125      3–3,5 yrs 81–87%
//   Toyota Avanza  3 yrs ≈ 75%  5 yrs ≈ 76%    7 yrs ≈ 60%   10 yrs 60–74%
//   Honda Brio     3–5 yrs 81–87%              9 yrs 61–71%
//   iPhone 13      4 yrs 42–54% of its launch price
// and each curve runs along the LOW side of those bands: the estimate is the
// lowest realistic second-hand price, what a quick sale would fetch, so net
// worth is never overstated. Asking prices run up to `askingPremium` above
// it, shown as a range.
//
// House prices rose only 1–2,3% a year in 2024–25 (BI's residential index,
// Rumah123's resale index); land has no national index, so it gets a modest
// rate rather than the 10–15% that circulates in sales copy.
//
// Kinds are the universal ones only. Livestock and rice fields depend too much
// on the region to estimate well, so they wait.

enum AssetKind: String, CaseIterable, Identifiable, Codable {
    case house, land, motorcycle, car, electronics, other
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .house:       return loc("asset.kind.house")
        case .land:        return loc("asset.kind.land")
        case .motorcycle:  return loc("asset.kind.motorcycle")
        case .car:         return loc("asset.kind.car")
        case .electronics: return loc("asset.kind.electronics")
        case .other:       return loc("asset.kind.other")
        }
    }

    var icon: String {
        switch self {
        case .house:       return "house.fill"
        case .land:        return "map.fill"
        case .motorcycle:  return "motorcycle"
        case .car:         return "car.fill"
        case .electronics: return "iphone"
        case .other:       return "shippingbox.fill"
        }
    }

    var color: Color {
        switch self {
        case .house:       return AppTheme.teal
        case .land:        return AppTheme.accent
        case .motorcycle:  return AppTheme.orange
        case .car:         return AppTheme.blue
        case .electronics: return AppTheme.purple
        case .other:       return AppTheme.slate
        }
    }

    /// Typical yearly change in value after the first year, in percent. Rough
    /// on purpose — the user can set the real value whenever they know it.
    var defaultAnnualRate: Double {
        switch self {
        case .house:       return 2
        case .land:        return 3
        case .motorcycle:  return -6
        case .car:         return -4
        case .electronics: return -15
        case .other:       return 0
        }
    }

    /// Share lost in the first year of owning it, in percent: the drop from
    /// "new" to "second-hand". Zero for what doesn't wear out.
    var firstYearDrop: Double {
        switch self {
        case .motorcycle:  return 10
        case .car:         return 15
        case .electronics: return 20
        default:                return 0
        }
    }


    /// Kinds that wear out and get replaced: the ones a replacement fund is for.
    var isReplaceable: Bool { self == .motorcycle || self == .car || self == .electronics }

    /// A yearly tax with a due date: STNK for vehicles, PBB for house and land.
    var taxLabel: String? {
        switch self {
        case .motorcycle, .car: return loc("asset.tax.stnk")
        case .house, .land:     return loc("asset.tax.pbb")
        default:                return nil
        }
    }
}

@Model
final class PhysicalAsset {
    var id: UUID
    var kindRaw: String
    var name: String
    var currency: String
    var purchasePrice: Double
    var purchaseDate: Date
    /// A value the user set themselves (0 = none). The estimate carries on
    /// from it at the kind's rate, starting at `manualValueDate`.
    var manualValue: Double
    var manualValueDate: Date?
    /// Yearly change in percent; negative wears out. Starts at the kind's default.
    var annualRate: Double
    /// Next yearly tax due date (STNK / PBB). Recurs every year on the same day.
    var taxDueDate: Date?
    var notes: String
    var createdAt: Date
    var sortOrder: Int

    init(kind: AssetKind, name: String, currency: String, purchasePrice: Double,
         purchaseDate: Date, annualRate: Double? = nil, taxDueDate: Date? = nil,
         notes: String = "", sortOrder: Int = 0) {
        self.id = UUID()
        self.kindRaw = kind.rawValue
        self.name = name
        self.currency = currency
        self.purchasePrice = purchasePrice
        self.purchaseDate = purchaseDate
        self.manualValue = 0
        self.manualValueDate = nil
        self.annualRate = annualRate ?? kind.defaultAnnualRate
        self.taxDueDate = taxDueDate
        self.notes = notes
        self.createdAt = .now
        self.sortOrder = sortOrder
    }

    var kind: AssetKind { AssetKind(rawValue: kindRaw) ?? .other }

    /// The rate the estimate uses: always the kind's current default. Nothing
    /// lets a user set `annualRate`, so a stored value is only ever an older
    /// default, and the rates are recalibrated as market data comes in. A
    /// user who knows better enters the value itself, which wins.
    var effectiveRate: Double { kind.defaultAnnualRate }

    var valuation: AssetValuation.Input {
        AssetValuation.Input(purchasePrice: purchasePrice, purchaseDate: purchaseDate,
                             manualValue: manualValue, manualValueDate: manualValueDate,
                             annualRate: effectiveRate, firstYearDrop: kind.firstYearDrop)
    }

    /// Lowest realistic price and a typical asking price, for things sold second-hand.
    func marketRange(at date: Date = .now) -> ClosedRange<Double>? {
        guard kind.firstYearDrop > 0 else { return nil }
        let low = value(at: date)
        return low...(low * (1 + AssetValuation.askingPremium))
    }

    func value(at date: Date = .now) -> Double { AssetValuation.value(valuation, at: date) }
}

// MARK: - Valuation

enum AssetValuation {
    struct Input: Equatable {
        var purchasePrice: Double
        var purchaseDate: Date
        var manualValue: Double = 0
        var manualValueDate: Date? = nil
        var annualRate: Double
        /// Percent lost over the first year after purchase.
        var firstYearDrop: Double = 0
    }

    /// Marketplace asking prices sit up to this much above what a quick sale
    /// fetches; the listings the curve was fitted to spread about this wide.
    static let askingPremium = 0.15

    /// Something that wears out is never worth nothing on paper — a ten-year-old
    /// motorbike still sells. Value floors at this share of where it started.
    static let wearFloor = 0.10

    /// From the latest known value: the user's own figure when there is one,
    /// else the purchase price. From the purchase price, the first year's drop
    /// comes first, spread evenly across that year, then the yearly rate
    /// compounds. A value the user set is already second-hand, so it only
    /// takes the yearly rate.
    static func value(_ i: Input, at date: Date) -> Double {
        let fromUser = i.manualValue > 0
        let (base, from) = fromUser
            ? (i.manualValue, i.manualValueDate ?? i.purchaseDate)
            : (i.purchasePrice, i.purchaseDate)
        guard base > 0 else { return 0 }
        let years = max(0, date.timeIntervalSince(from) / (365.25 * 86_400))
        let grown: Double
        if fromUser || i.firstYearDrop <= 0 {
            grown = base * pow(1 + i.annualRate / 100, years)
        } else {
            let first = 1 - i.firstYearDrop / 100 * min(years, 1)
            grown = base * first * pow(1 + i.annualRate / 100, max(years - 1, 0))
        }
        return i.annualRate < 0 || i.firstYearDrop > 0 ? max(grown, base * wearFloor) : grown
    }

    /// Value lost (negative) or gained over the coming year, from today's value.
    static func yearlyChange(_ i: Input, at date: Date = .now) -> Double {
        let now = value(i, at: date)
        let next = value(i, at: date.addingTimeInterval(365.25 * 86_400))
        return next - now
    }
}

/// The year's total wear across replaceable things, and what to set aside for it.
struct AssetSummary: Equatable {
    var totalValue: Double = 0
    /// Top of the market range: `totalValue` with asking prices for what is
    /// sold second-hand. Equal to `totalValue` when nothing is.
    var marketHigh: Double = 0
    var purchaseTotal: Double = 0
    /// Value lost per month across things that wear out (positive number).
    var monthlyWear: Double = 0
    /// The wearing assets, for naming them in advice.
    var wearingNames: [String] = []

    @MainActor
    static func of(_ assets: [PhysicalAsset], currency: String, now: Date = .now) -> AssetSummary {
        let cm = CurrencyManager.shared
        var s = AssetSummary()
        for a in assets {
            let conv = { (v: Double) in cm.convert(v, from: a.currency, to: currency) }
            s.totalValue += conv(a.value(at: now))
            s.marketHigh += conv(a.marketRange(at: now)?.upperBound ?? a.value(at: now))
            s.purchaseTotal += conv(a.purchasePrice)
            if a.kind.isReplaceable {
                let change = AssetValuation.yearlyChange(a.valuation, at: now)
                if change < 0 {
                    s.monthlyWear += conv(-change) / 12
                    s.wearingNames.append(a.name)
                }
            }
        }
        return s
    }
}
