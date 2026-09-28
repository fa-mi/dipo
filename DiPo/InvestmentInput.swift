import Foundation

// MARK: - Investment input
//
// What the investment forms do with the text a person types, kept pure so it
// can be pinned by tests (InvestmentInputTests). Three jobs:
//
//   • reading a number however it was written — "1.000.000", "0,1308", and
//     also "0.134582962" or "$1,234.56" copied from a foreign broker's app;
//   • writing one back into a field so it reads the same way again;
//   • turning a TOTAL into a per-unit price, and noticing when a per-gram
//     gold price can't be one.
//
// The last one exists because gold apps (BRImo/Tring, Pegadaian, Pluang) show
// the balance as a rupiah total and quote prices per 0,01 gram. Typing that
// total into "price per gram" gave a holding worth a seventh of the real one,
// with nothing on screen to say so.

nonisolated enum InvestmentInput {

    /// Parse a typed number. Returns 0 for anything unreadable.
    ///
    /// Indonesian writing ("1.234.567,89") and English ("1,234,567.89") both
    /// come in, so the separators are read from their shape:
    ///   • both present → whichever comes LAST is the decimal point;
    ///   • one kind, repeated → grouping ("1.000.000", "1,000,000");
    ///   • a single comma → decimal ("0,5", "366,51"), the id-ID habit;
    ///   • a single dot → grouping only when it is followed by exactly three
    ///     digits and something other than 0 comes before it ("16.160",
    ///     "200.000"). "0.1308", "366.51" and "0.134582962" are decimals.
    static func number(_ raw: String) -> Double {
        let s = raw.filter { !$0.isWhitespace }
        guard !s.isEmpty else { return 0 }
        let lastDot = s.lastIndex(of: ".")
        let lastComma = s.lastIndex(of: ",")

        var normalized: String
        switch (lastDot, lastComma) {
        case let (dot?, comma?):
            normalized = dot > comma
                ? s.replacingOccurrences(of: ",", with: "")
                : s.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
        case (nil, _?):
            normalized = s.filter { $0 == "," }.count > 1
                ? s.replacingOccurrences(of: ",", with: "")
                : s.replacingOccurrences(of: ",", with: ".")
        case (_?, nil):
            let parts = s.split(separator: ".", omittingEmptySubsequences: false)
            if parts.count > 2 {
                normalized = s.replacingOccurrences(of: ".", with: "")
            } else {
                let whole = parts[0], fraction = parts[1]
                let isGrouping = fraction.count == 3 && !whole.isEmpty
                    && whole.contains(where: { $0 != "0" })
                normalized = isGrouping ? s.replacingOccurrences(of: ".", with: "") : s
            }
        case (nil, nil):
            normalized = s
        }
        guard let v = Double(normalized), v.isFinite, v >= 0 else { return 0 }
        return v
    }

    /// A number written back into a field: no grouping, a comma decimal, up
    /// to nine decimals and never scientific notation, so `number(text(v))`
    /// gives back v (0.00001 → "0,00001", not "1e-05").
    static func text(_ v: Double) -> String {
        guard v.isFinite else { return "" }
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 9
        return (f.string(from: v as NSNumber) ?? "0").replacingOccurrences(of: ".", with: ",")
    }

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
