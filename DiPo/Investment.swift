import SwiftUI
import SwiftData

// MARK: - Investment domain
//
// A Royal-only portfolio tracker. One `InvestmentHolding` per position (a gold
// savings account, a stock, a mutual fund, a bond, a deposit, a coin); its
// `InvestmentLot`s are the buys/sells/income against it. Valuation is done by
// PortfolioEngine — this file is just the stored shape + per-type presentation.
//
// Instruments differ in only two ways the model cares about: the UNIT they trade
// in, and whether their price can be fetched automatically or must be typed in.
// Everything else (cost basis, P/L, today's move) is identical maths.

enum InvestmentType: String, CaseIterable, Codable {
    case gold, stock, mutualFund, bond, deposit, crypto

    var displayName: String {
        switch self {
        case .gold:       return loc("invest.type.gold")
        case .stock:      return loc("invest.type.stock")
        case .mutualFund: return loc("invest.type.mutual_fund")
        case .bond:       return loc("invest.type.bond")
        case .deposit:    return loc("invest.type.deposit")
        case .crypto:     return loc("invest.type.crypto")
        }
    }

    /// The unit a position is measured in — shown next to quantities.
    var unitLabel: String {
        switch self {
        case .gold:       return loc("invest.unit.gram")
        case .stock:      return loc("invest.unit.share")
        case .mutualFund: return loc("invest.unit.unit")
        case .bond:       return loc("invest.unit.nominal")
        case .deposit:    return loc("invest.unit.nominal")
        case .crypto:     return loc("invest.unit.coin")
        }
    }

    var icon: String {
        switch self {
        case .gold:       return "seal.fill"
        case .stock:      return "chart.line.uptrend.xyaxis"
        case .mutualFund: return "chart.pie.fill"
        case .bond:       return "building.columns.fill"
        case .deposit:    return "banknote.fill"
        case .crypto:     return "bitcoinsign.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .gold:       return AppTheme.orange
        case .stock:      return AppTheme.blue
        case .mutualFund: return AppTheme.purple
        case .bond:       return AppTheme.teal
        case .deposit:    return AppTheme.accent
        case .crypto:     return AppTheme.amber
        }
    }

    /// Whether the price CAN be fetched (the app still lets the user override).
    /// Reksadana NAB and bond prices have no reliable free feed, so those are
    /// user-maintained by default; deposits never move.
    var supportsAutoPrice: Bool {
        switch self {
        case .gold, .stock, .crypto: return true
        case .mutualFund, .bond, .deposit: return false
        }
    }

    /// How often the price actually changes — sets honest expectations in the UI
    /// ("live" vs "daily" vs "fixed"), rather than implying everything ticks.
    enum Cadence { case live, daily, fixed }
    var cadence: Cadence {
        switch self {
        case .crypto, .stock: return .live      // crypto real-time; stock delayed but intraday
        case .gold, .mutualFund, .bond: return .daily
        case .deposit: return .fixed
        }
    }

    /// Deposits and non-tradable bonds don't have a fluctuating price; their
    /// "price" is fixed at 1.0 (value = amount put in, plus recorded interest).
    var priceIsFixed: Bool { self == .deposit }
}

enum InvestmentLotKind: String, CaseIterable, Codable {
    case buy, sell, dividend, coupon, fee

    var isIncome: Bool { self == .dividend || self == .coupon }
    var isCash: Bool { self == .dividend || self == .coupon || self == .fee }
}

@Model
final class InvestmentHolding {
    var id: UUID
    /// `InvestmentType` rawValue. Stored as a string so the enum can grow
    /// without a destructive migration.
    var typeRaw: String
    var name: String
    /// Price-lookup key for the fetch service (e.g. "BBCA" for a stock,
    /// "bitcoin" for crypto, "" when the price is maintained by hand).
    var symbol: String
    var currency: String
    var createdAt: Date

    // Cached quote (per unit, in `currency`). The lots are the source of truth
    // for cost; the price is the one thing that comes from outside them.
    var lastPrice: Double
    /// Previous session's close, so "today's change" is knowable.
    var prevClose: Double
    var priceUpdatedAt: Date?
    /// The user maintains the price by hand (auto-fetch off or unavailable).
    var manualPrice: Bool

    var sortOrder: Int

    @Relationship(deleteRule: .cascade)
    var lots: [InvestmentLot] = []

    init(type: InvestmentType, name: String, symbol: String = "",
         currency: String = CurrencyManager.shared.preferredCurrency,
         lastPrice: Double = 0, prevClose: Double = 0,
         manualPrice: Bool = false, sortOrder: Int = 0) {
        self.id = UUID()
        self.typeRaw = type.rawValue
        self.name = name
        self.symbol = symbol
        self.currency = currency
        self.createdAt = .now
        self.lastPrice = lastPrice
        self.prevClose = prevClose
        self.priceUpdatedAt = nil
        self.manualPrice = manualPrice || !type.supportsAutoPrice
        self.sortOrder = sortOrder
    }

    var type: InvestmentType { InvestmentType(rawValue: typeRaw) ?? .gold }

    /// Effective price used for valuation. A fixed-price instrument (deposit) is
    /// always 1.0 so value == amount recorded.
    var effectivePrice: Double { type.priceIsFixed ? 1 : lastPrice }

    var facts: [LotFact] { lots.map(\.fact) }

    /// Convenience: fully valued stats for this holding.
    func stats() -> HoldingStats {
        PortfolioEngine.stats(lots: facts, lastPrice: effectivePrice, prevClose: prevClose)
    }
}

@Model
final class InvestmentLot {
    var id: UUID
    var date: Date
    /// `InvestmentLotKind` rawValue.
    var kindRaw: String
    var units: Double
    var pricePerUnit: Double
    var fee: Double
    /// Cash figure for income/fee kinds (dividend, coupon, standalone fee).
    var cashAmount: Double
    var note: String
    /// When the purchase was funded from a card, the id of the cash-outflow
    /// `TxRecord` that recorded it — so deleting this lot can reverse the card
    /// movement. Empty when the lot was recorded without touching a card.
    var linkedCardTxID: String

    init(kind: InvestmentLotKind, date: Date = .now,
         units: Double = 0, pricePerUnit: Double = 0, fee: Double = 0,
         cashAmount: Double = 0, note: String = "", linkedCardTxID: String = "") {
        self.id = UUID()
        self.date = date
        self.kindRaw = kind.rawValue
        self.units = units
        self.pricePerUnit = pricePerUnit
        self.fee = fee
        self.cashAmount = cashAmount
        self.note = note
        self.linkedCardTxID = linkedCardTxID
    }

    var kind: InvestmentLotKind { InvestmentLotKind(rawValue: kindRaw) ?? .buy }

    var fact: LotFact {
        LotFact(date: date, kind: kindRaw, units: units,
                pricePerUnit: pricePerUnit, fee: fee, cashAmount: cashAmount)
    }
}
