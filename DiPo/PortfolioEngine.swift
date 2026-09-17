import Foundation

// MARK: - Portfolio Engine
//
// The pure maths behind the Investment menu. Every instrument — gold, stocks,
// mutual funds, bonds, deposits, crypto — reduces to the SAME shape: a series of
// lots (buy / sell / income) against a current price. So one engine values them
// all; only the price SOURCE and the unit LABEL differ per type.
//
// Framework-free and deterministic (like RollupEngine): it takes `LotFact`
// values, never SwiftData models, so the arithmetic can be executed in isolation
// and pinned by tests. Cost basis is weighted-average (the method Indonesian
// brokers and Tabungan Emas use), so adding to a position blends the average
// buy price — which is exactly the "harga rata-rata naik/turun" the user asked
// to see.

/// A framework-free projection of one investment transaction.
struct LotFact: Equatable {
    let date: Date
    /// "buy" | "sell" | "dividend" | "coupon" | "fee"
    let kind: String
    /// Units moved (gram / lembar / unit / coin). 0 for cash-only kinds.
    let units: Double
    /// Price per unit at the transaction, in the holding's currency.
    let pricePerUnit: Double
    /// Broker/admin fee on this transaction, in the holding's currency.
    let fee: Double
    /// The cash figure for income/fee kinds (dividend, coupon, standalone fee).
    let cashAmount: Double

    init(date: Date, kind: String, units: Double = 0, pricePerUnit: Double = 0,
         fee: Double = 0, cashAmount: Double = 0) {
        self.date = date
        self.kind = kind
        self.units = units
        self.pricePerUnit = pricePerUnit
        self.fee = fee
        self.cashAmount = cashAmount
    }
}

/// Everything one holding is worth and how it got there — all in the holding's
/// own currency. Convert to a display currency at the portfolio layer.
struct HoldingStats: Equatable {
    var unitsHeld: Double = 0
    /// Cost of the units STILL held (weighted average × unitsHeld).
    var costBasis: Double = 0
    /// Weighted-average buy price per unit of the units still held.
    var avgCost: Double = 0
    /// Gross rupiah ever put in via buys, incl. fees — the "modal" figure.
    var invested: Double = 0
    var realizedPL: Double = 0
    var income: Double = 0

    // Needs the current price:
    var marketValue: Double = 0
    var unrealizedPL: Double = 0
    var unrealizedPct: Double = 0
    var todayChange: Double = 0
    /// Unrealized + realized + income — total money made on this holding.
    var totalReturn: Double = 0
}

/// Portfolio-wide totals, already converted into one display currency.
struct PortfolioTotals: Equatable {
    var marketValue: Double = 0
    /// Cost basis of currently-held positions (what the holdings are "worth at cost").
    var costBasis: Double = 0
    var unrealizedPL: Double = 0
    var unrealizedPct: Double = 0
    var todayChange: Double = 0
    var realizedPL: Double = 0
    var income: Double = 0
    /// Market value per instrument type (rawValue → value) for the allocation ring.
    var valueByType: [String: Double] = [:]
}

enum PortfolioEngine {

    /// Value one holding from its lots and its latest/previous price.
    ///
    /// Weighted-average cost: each buy blends into the average; each sell realises
    /// gain against that average and removes its share of the cost basis, so the
    /// average of what REMAINS is unchanged by a sale (the correct behaviour).
    static func stats(lots: [LotFact], lastPrice: Double, prevClose: Double = 0) -> HoldingStats {
        var s = HoldingStats()
        for l in lots.sorted(by: { $0.date < $1.date }) {
            switch l.kind {
            case "buy":
                let cost = l.units * l.pricePerUnit + l.fee
                s.costBasis += cost
                s.invested  += cost
                s.unitsHeld += l.units
            case "sell":
                let avg = s.unitsHeld > 0 ? s.costBasis / s.unitsHeld : 0
                let proceeds = l.units * l.pricePerUnit - l.fee
                s.realizedPL += proceeds - l.units * avg
                s.costBasis  -= l.units * avg
                s.unitsHeld  -= l.units
                // Guard against tiny negative residue from float drift.
                if s.unitsHeld < 1e-9 { s.unitsHeld = 0; s.costBasis = 0 }
            case "dividend", "coupon":
                s.income += l.cashAmount
            case "fee":
                s.realizedPL -= l.cashAmount
            default:
                break
            }
        }
        s.avgCost      = s.unitsHeld > 0 ? s.costBasis / s.unitsHeld : 0
        s.marketValue  = s.unitsHeld * lastPrice
        s.unrealizedPL = s.marketValue - s.costBasis
        s.unrealizedPct = s.costBasis > 0 ? s.unrealizedPL / s.costBasis : 0
        // Only when a previous close is known — otherwise "today" is unknowable
        // and a zero is more honest than pretending the whole value moved.
        s.todayChange  = prevClose > 0 ? s.unitsHeld * (lastPrice - prevClose) : 0
        s.totalReturn  = s.unrealizedPL + s.realizedPL + s.income
        return s
    }

    /// Roll per-holding stats up into one display currency. Each holding keeps
    /// its own currency (crypto often USD, the rest IDR); conversion happens here
    /// with the live rate, never frozen into the stored figures.
    static func portfolio(_ holdings: [(type: String, currency: String, stats: HoldingStats)],
                          targetCurrency: String,
                          convert: (Double, String, String) -> Double) -> PortfolioTotals {
        func toTarget(_ amount: Double, _ from: String) -> Double {
            if amount == 0 { return 0 }
            return from == targetCurrency ? amount : convert(amount, from, targetCurrency)
        }
        var out = PortfolioTotals()
        for h in holdings {
            let mv = toTarget(h.stats.marketValue, h.currency)
            out.marketValue += mv
            out.costBasis   += toTarget(h.stats.costBasis, h.currency)
            out.unrealizedPL += toTarget(h.stats.unrealizedPL, h.currency)
            out.todayChange += toTarget(h.stats.todayChange, h.currency)
            out.realizedPL  += toTarget(h.stats.realizedPL, h.currency)
            out.income      += toTarget(h.stats.income, h.currency)
            out.valueByType[h.type, default: 0] += mv
        }
        out.unrealizedPct = out.costBasis > 0 ? out.unrealizedPL / out.costBasis : 0
        return out
    }
}
