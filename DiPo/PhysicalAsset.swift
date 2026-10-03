import SwiftUI
import SwiftData

// MARK: - Physical assets (Royal)
//
// What a household owns outside its accounts — the house, the land, the
// motorbike, the phone. For many DiPo users this is most of what they have,
// and leaving it out made net worth read as if it didn't exist.
//
// Valued by estimate: the purchase price moved by a yearly rate for the kind
// (a motorbike loses about 12% a year, land gains about 5%), or from a value
// the user set themselves when they know better. Never counted as emergency
// money — none of it turns into cash within days.
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
        case .motorcycle:  return "scooter"
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

    /// Typical yearly change in value, in percent. Rough on purpose — the user
    /// can set the real value whenever they know it.
    var defaultAnnualRate: Double {
        switch self {
        case .house:       return 3
        case .land:        return 5
        case .motorcycle:  return -12
        case .car:         return -12
        case .electronics: return -25
        case .other:       return 0
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

    var valuation: AssetValuation.Input {
        AssetValuation.Input(purchasePrice: purchasePrice, purchaseDate: purchaseDate,
                             manualValue: manualValue, manualValueDate: manualValueDate,
                             annualRate: annualRate)
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
    }

    /// Something that wears out is never worth nothing on paper — a ten-year-old
    /// motorbike still sells. Value floors at this share of where it started.
    static let wearFloor = 0.10

    /// Compounded yearly from the latest known value: the user's own figure
    /// when there is one, else the purchase price.
    static func value(_ i: Input, at date: Date) -> Double {
        let (base, from) = i.manualValue > 0
            ? (i.manualValue, i.manualValueDate ?? i.purchaseDate)
            : (i.purchasePrice, i.purchaseDate)
        guard base > 0 else { return 0 }
        let years = max(0, date.timeIntervalSince(from) / (365.25 * 86_400))
        let grown = base * pow(1 + i.annualRate / 100, years)
        return i.annualRate < 0 ? max(grown, base * wearFloor) : grown
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
