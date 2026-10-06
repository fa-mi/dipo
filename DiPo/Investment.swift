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
    /// A retirement fund (DPLK — BRIFINE, Manulife, AIA…): a rupiah balance
    /// that grows with its fund's return, locked until retirement. Kept apart
    /// in the totals so locked money never reads as money to hand.
    case pension

    var displayName: String {
        switch self {
        case .gold:       return loc("invest.type.gold")
        case .stock:      return loc("invest.type.stock")
        case .mutualFund: return loc("invest.type.mutual_fund")
        case .bond:       return loc("invest.type.bond")
        case .deposit:    return loc("invest.type.deposit")
        case .crypto:     return loc("invest.type.crypto")
        case .pension:    return loc("invest.type.pension")
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
        case .pension:    return loc("invest.unit.nominal")
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
        case .pension:    return "beach.umbrella.fill"
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
        case .pension:    return AppTheme.indigo
        }
    }

    /// Whether the price can be fetched automatically. Only the instruments with
    /// a reliable free feed the app can reach directly: crypto (CoinGecko) and
    /// IDX stocks (Yahoo, delayed). Gold (Antam), reksadana NAB and bond prices
    /// have no such feed, so they're user-maintained; deposits never move.
    var supportsAutoPrice: Bool {
        switch self {
        case .stock, .crypto: return true
        case .gold, .mutualFund, .bond, .deposit, .pension: return false
        }
    }

    /// How often the price actually changes — sets honest expectations in the UI
    /// ("live" vs "daily" vs "fixed"), rather than implying everything ticks.
    enum Cadence { case live, daily, monthly, fixed }
    var cadence: Cadence {
        switch self {
        case .crypto, .stock: return .live      // crypto real-time; stock delayed but intraday
        case .gold, .mutualFund, .bond: return .daily
        case .pension: return .monthly           // the fund reports its balance monthly
        case .deposit: return .fixed
        }
    }

    /// Money that can't be drawn until retirement.
    var isLocked: Bool { self == .pension }

    /// Deposits and non-tradable bonds don't have a fluctuating price; their
    /// "price" is fixed at 1.0 (value = amount put in, plus recorded interest).
    var priceIsFixed: Bool { self == .deposit }
}

enum InvestmentLotKind: String, CaseIterable, Codable, Identifiable {
    case buy, sell, dividend, coupon, fee

    var id: String { rawValue }
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

    /// A short trail of recent prices for the row sparkline. Grows as the price
    /// is refreshed or updated; capped so it never bloats. Defaulted, so adding
    /// it is a lightweight migration.
    var priceHistory: [Double] = []

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

    /// Append a price point for the sparkline, keeping the trail bounded and
    /// skipping exact repeats so a flat line doesn't accumulate noise.
    func pushPrice(_ p: Double) {
        guard p > 0 else { return }
        if let last = priceHistory.last, abs(last - p) < 1e-9 { return }
        priceHistory.append(p)
        if priceHistory.count > 40 { priceHistory.removeFirst(priceHistory.count - 40) }
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

// MARK: - Gold price feed

/// Pegadaian's daily Tabungan Emas price — what BRImo (Tring by Pegadaian)
/// and the Pegadaian app value a gold balance at. Served by the Worker
/// (dipo-backend src/prices.js) under this one symbol.
enum GoldFeed {
    static let symbol = "pegadaian"
}

extension InvestmentHolding {
    /// Whether this holding's price comes from a feed rather than by hand:
    /// a stock or a coin with a symbol, or rupiah gold following Pegadaian.
    var isAutoPriced: Bool {
        let sym = symbol.trimmingCharacters(in: .whitespaces)
        guard !manualPrice, !sym.isEmpty else { return false }
        if type.supportsAutoPrice { return true }
        return followsGoldFeed
    }

    /// Which gold this is, for rupiah gold; `.manual` for anything else.
    var goldSource: GoldSource {
        guard type == .gold, currency.uppercased() == "IDR" else { return .manual }
        return GoldSource(symbol: symbol)
    }

    /// Gold set to follow a price feed (on or paused): savings, a bar brand
    /// or jewellery by purity.
    var followsGoldFeed: Bool { goldSource != .manual }

    /// Follow a gold source's price, or keep it by hand. Pausing keeps the
    /// source, so turning the feed back on picks up where it was.
    func setGoldSource(_ source: GoldSource) {
        guard type == .gold, currency.uppercased() == "IDR" else { return }
        symbol = source.symbol
        manualPrice = source == .manual
    }

    /// Turn the feed on (savings unless a source is already chosen) or pause it.
    func setGoldFeed(_ on: Bool) {
        guard type == .gold, currency.uppercased() == "IDR" else { return }
        if on {
            if goldSource == .manual { symbol = GoldFeed.symbol }
            manualPrice = false
        } else {
            manualPrice = true
        }
    }
}
