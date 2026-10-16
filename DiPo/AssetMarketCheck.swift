import Foundation

// MARK: - Checking an asset against the market
//
// Shares, gold and crypto have one price, published by an exchange, so DiPo
// follows them by itself. Second-hand things have no such feed: OLX, Mobil123
// and the rest publish no price API, and every unit differs in mileage,
// condition and city. So the curve in PhysicalAsset carries the value between
// looks, and now and then the user looks at real listings — one tap opens
// them, already searched — and enters what they see. That becomes the new
// starting point for the curve.

enum AssetMarketCheck {
    /// Where the tap goes. OLX for a vehicle priced in rupiah: its used-car
    /// and used-motorbike categories list the most units and show prices in
    /// the results. Everything else — electronics span several OLX
    /// categories, a house's price is about its street, another currency is
    /// another country's market — goes to a web search.
    enum Site: Equatable { case olx, web }

    static func site(kind: AssetKind, currency: String) -> Site {
        guard currency == "IDR" else { return .web }
        return olxCategory(kind) == nil ? .web : .olx
    }

    /// OLX Indonesia's category paths: Mobil Bekas and Motor Bekas.
    private static func olxCategory(_ kind: AssetKind) -> String? {
        switch kind {
        case .car:        return "mobil-bekas_c198"
        case .motorcycle: return "motor-bekas_c200"
        default:          return nil
        }
    }

    /// What to search for: the name, plus the year for a vehicle, whose price
    /// turns on it — unless the name already carries one ("Brio RS 2017").
    /// Bought new, the vehicle's year is the year it was bought; bought
    /// second-hand, it isn't, and a wrong year finds the wrong cars, so the
    /// search goes without one (the form asks for it in the name). A phone's
    /// or laptop's name already says its generation.
    static func query(name: String, kind: AssetKind, purchaseDate: Date, boughtUsed: Bool = false,
                      cal: Calendar = .current) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard kind == .car || kind == .motorcycle, !boughtUsed, !nameHasYear(trimmed) else { return trimmed }
        return "\(trimmed) \(cal.component(.year, from: purchaseDate))"
    }

    /// "Brio RS 2015" says its year; "Brio RS" doesn't.
    static func nameHasYear(_ name: String) -> Bool {
        name.range(of: #"\b(19|20)\d{2}\b"#, options: .regularExpression) != nil
    }

    struct Link: Equatable {
        let site: Site
        let url: URL
    }

    /// The listings for this asset, already searched. Nil without a name.
    /// The name goes to that site only when the user taps, and the button
    /// names the site.
    static func link(name: String, kind: AssetKind, purchaseDate: Date, boughtUsed: Bool = false,
                     currency: String, cal: Calendar = .current) -> Link? {
        let q = query(name: name, kind: kind, purchaseDate: purchaseDate, boughtUsed: boughtUsed, cal: cal)
        guard !q.isEmpty else { return nil }
        // A name with no Latin letters or digits leaves OLX nothing to search
        // but the year.
        if site(kind: kind, currency: currency) == .olx, let category = olxCategory(kind),
           !olxSlug(name).isEmpty,
           let url = URL(string: "https://www.olx.co.id/\(category)/q-\(olxSlug(q))") {
            return Link(site: .olx, url: url)
        }
        let suffix = loc(kind.firstYearDrop > 0 ? "asset.market.search_used" : "asset.market.search_price")
        guard let encoded = "\(q) \(suffix)".addingPercentEncoding(withAllowedCharacters: unreserved),
              let url = URL(string: "https://www.google.com/search?q=\(encoded)") else { return nil }
        return Link(site: .web, url: url)
    }

    /// RFC 3986's unreserved characters. Everything else in the search is
    /// percent-encoded, "&" and "+" too, so the whole name stays the search
    /// term: an "&" would start another parameter, a "+" would read as a space.
    private static let unreserved = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    /// OLX's search path: lowercase words joined by hyphens, "honda-brio-rs-2017".
    /// Only ASCII letters and digits survive, so nothing in the name can add
    /// a path segment, a query or a fragment to the URL.
    static func olxSlug(_ text: String) -> String {
        var out = ""
        var pendingDash = false
        for ch in text.lowercased().unicodeScalars {
            if (97...122).contains(ch.value) || (48...57).contains(ch.value) {   // a-z, 0-9
                if pendingDash && !out.isEmpty { out.append("-") }
                out.unicodeScalars.append(ch)
                pendingDash = false
            } else {
                pendingDash = true
            }
        }
        return out
    }

    // MARK: When to look again

    /// How long a value holds before DiPo suggests a look: half a year for
    /// what is sold second-hand, whose prices move with new models and the
    /// season; a year for house, land and the rest, which move slowly.
    static func interval(for kind: AssetKind) -> TimeInterval {
        (kind.firstYearDrop > 0 ? 182 : 365) * 86_400
    }

    /// When the value was last looked at: the day the user entered their own
    /// value, else the day the asset was added — they saw DiPo's estimate
    /// then, in the sheet, and kept it.
    static func lastChecked(createdAt: Date, manualValue: Double, manualValueDate: Date?) -> Date {
        guard manualValue > 0, let set = manualValueDate else { return createdAt }
        return max(set, createdAt)
    }

    static func isDue(kind: AssetKind, lastChecked: Date, now: Date) -> Bool {
        now.timeIntervalSince(lastChecked) >= interval(for: kind)
    }

    /// The names of the assets due a look, oldest look first.
    @MainActor
    static func due(_ assets: [PhysicalAsset], now: Date = .now) -> [String] {
        assets.filter { $0.isMarketCheckDue(now: now) }
            .sorted { $0.lastMarketCheck < $1.lastMarketCheck }
            .map(\.name)
    }

    // MARK: DiPo's reminder on Home

    /// Seen once, DiPo leaves it for a month: the rows on the Assets screen
    /// keep saying which ones are due. Kept on this device, like Home's
    /// other preferences.
    static let snoozeKey = "asset_check_snoozed_until"
    static let snoozeLength: TimeInterval = 30 * 86_400

    static func isSnoozed(until: Double, now: Date = .now) -> Bool {
        now.timeIntervalSince1970 < until
    }

    static func snoozed(from now: Date = .now) -> Double {
        now.addingTimeInterval(snoozeLength).timeIntervalSince1970
    }
}

extension PhysicalAsset {
    var lastMarketCheck: Date {
        AssetMarketCheck.lastChecked(createdAt: createdAt, manualValue: manualValue,
                                     manualValueDate: manualValueDate)
    }

    func isMarketCheckDue(now: Date = .now) -> Bool {
        AssetMarketCheck.isDue(kind: kind, lastChecked: lastMarketCheck, now: now)
    }
}
