import Foundation

// MARK: - Number input
//
// Every amount field in the app reads the person's text through here, so
// "25.000" means twenty-five thousand rupiah on every screen, not twenty-five
// on one and twenty-five thousand on the next. Before this, most fields did
// `Double(text)`: "25.000" saved Rp25 and "1.000.000" saved nothing at all,
// while the preview under the field and the investment forms each had their
// own rules. Pinned by NumberInputTests.
//
// Two readers, because the same text means different things:
//   • `amount` — money and quantities, where a dot before three digits is a
//     thousands separator in Indonesian writing;
//   • `decimal` — rates and percentages, where "1.875" can only be 1,875%.

nonisolated enum NumberInput {

    /// Parse a typed amount. Returns 0 for anything unreadable or negative.
    ///
    /// A currency marker copied along with the number ("Rp 25.000", "$12.43")
    /// is ignored. Indonesian ("1.234.567,89") and English ("1,234,567.89")
    /// writing both come in, so separators are read from their shape:
    ///   • both present → whichever comes LAST is the decimal point;
    ///   • one kind, repeated → grouping ("1.000.000", "1,000,000");
    ///   • a single comma → decimal ("0,5", "366,51"), the id-ID habit;
    ///   • a single dot → grouping only when it is followed by exactly three
    ///     digits and something other than 0 comes before it ("25.000",
    ///     "200.000"). "0.1308", "366.51" and "0.134582962" are decimals.
    static func amount(_ raw: String) -> Double {
        guard let s = cleaned(raw) else { return 0 }
        let lastDot = s.lastIndex(of: ".")
        let lastComma = s.lastIndex(of: ",")

        let normalized: String
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
        return finite(normalized)
    }

    /// Parse a rate or percentage: a single dot or comma is always the
    /// decimal point ("1.875", "1,875" → 1.875). A second separator can only
    /// be grouping, so the last one is taken as the decimal.
    static func decimal(_ raw: String) -> Double {
        guard let s = cleaned(raw) else { return 0 }
        guard let last = s.lastIndex(where: { $0 == "." || $0 == "," }) else { return finite(s) }
        let whole = s[..<last].filter { $0 != "." && $0 != "," }
        let fraction = s[s.index(after: last)...]
        return finite("\(whole).\(fraction)")
    }

    /// A number written back into a field: no grouping, a comma decimal, up
    /// to nine decimals and never scientific notation, so `amount(text(v))`
    /// and `decimal(text(v))` both give back v (1234.567 → "1234,567", not
    /// "1234.567", which would read as grouping). 0 gives "0".
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

    /// Whether the text holds a number at all — for fields where 0 is a valid
    /// answer (a 0% rate) but an empty or junk field is not.
    static func isNumber(_ raw: String) -> Bool { cleaned(raw) != nil }

    // MARK: Helpers

    /// Only digits and separators survive; a minus sign makes it unreadable
    /// (amount fields hold magnitudes). nil when nothing numeric is left.
    private static func cleaned(_ raw: String) -> String? {
        if raw.contains("-") { return nil }
        let s = raw.filter { $0.isASCII && ($0.isNumber || $0 == "." || $0 == ",") }
        return s.contains(where: \.isNumber) ? s : nil
    }

    private static func finite(_ s: String) -> Double {
        guard let v = Double(s), v.isFinite, v >= 0 else { return 0 }
        return v
    }
}
