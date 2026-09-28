import Foundation

// MARK: - Investment input
//
// What the investment forms do with the text a person types, kept pure so it
// can be pinned by tests (InvestmentInputTests). Reading and writing numbers
// is NumberInput's job; this adds turning a TOTAL into a per-unit price, and
// noticing when a per-gram gold price can't be one.
//
// That last one exists because gold apps (BRImo/Tring, Pegadaian, Pluang) show
// the balance as a rupiah total and quote prices per 0,01 gram. Typing that
// total into "price per gram" gave a holding worth a seventh of the real one,
// with nothing on screen to say so.

nonisolated enum InvestmentInput {

    /// Parse a typed number — `NumberInput.amount`, shared with every other
    /// amount field in the app.
    static func number(_ raw: String) -> Double { NumberInput.amount(raw) }

    /// A number written back into a field so `number` reads it back unchanged.
    static func text(_ v: Double) -> String { NumberInput.text(v) }

    /// Whether a price field holds the price of ONE unit or the total paid for
    /// (or worth of) the whole quantity.
    enum PriceMode: String, CaseIterable {
        case perUnit, total
    }

    /// The per-unit price a field means. A total is spread over the units; with
    /// no units yet there is nothing to spread it over.
    static func perUnitPrice(_ entered: Double, units: Double, mode: PriceMode) -> Double {
        switch mode {
        case .perUnit: return entered
        case .total:   return units > 0 ? entered / units : 0
        }
    }

    /// A plausible rupiah price for one gram of gold. Antam and Tring have
    /// traded between roughly Rp1 and 2,5 juta a gram in recent years; the
    /// band is wide on purpose, so only a figure off by a whole order of
    /// magnitude — a total, a price per 0,01 gram, a missing zero — trips it.
    static let plausibleGoldIDRPerGram: ClosedRange<Double> = 500_000...20_000_000

    /// True when `perGram` can't be a gold price. Only judged in rupiah: other
    /// currencies aren't what these apps quote in, and a wrong warning is worse
    /// than none.
    static func goldPriceLooksWrong(perGram: Double, currency: String) -> Bool {
        guard perGram > 0, currency.uppercased() == "IDR" else { return false }
        return !plausibleGoldIDRPerGram.contains(perGram)
    }
}

// MARK: - Stock markets

/// Where a stock trades. It decides the currency the holding is kept in and
/// the ticker the price is looked up under; the market itself is not stored —
/// a holding's currency already says it (IDR → IDX, anything else → abroad).
nonisolated enum StockMarket: String, CaseIterable {
    case idx, us

    var currency: String {
        switch self {
        case .idx: return "IDR"
        case .us:  return "USD"
        }
    }

    static func of(currency: String) -> StockMarket {
        currency.uppercased() == "IDR" ? .idx : .us
    }

    /// The Yahoo Finance ticker for a symbol held in `currency`. IDX tickers
    /// need ".JK"; US tickers have no suffix ("AAPL", "BRK-B"). A symbol that
    /// already names its market ("BBCA.JK", "7203.T") is left alone. The
    /// Worker builds the same ticker (dipo-backend src/prices.js).
    static func yahooTicker(symbol: String, currency: String) -> String {
        let s = symbol.trimmingCharacters(in: .whitespaces).uppercased()
        if s.contains(".") { return s }
        return of(currency: currency) == .idx ? "\(s).JK" : s
    }
}
