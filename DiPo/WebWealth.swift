import Foundation

// MARK: - What you have, for the web dashboard
//
// Three sections on dipo.info/dashboard.html, after the period ones:
// "Hartamu hari ini" (Home's net worth, as what you have against what you
// owe), "Investasimu" and "Barang berhargamu". The phone computes every
// figure, with the functions its own screens use (NetWorth.parts,
// HoldingStats, PhysicalAsset.value); the page lays them out.
//
// Only what those sections print. Not sent: lots, price history, stock or
// coin codes, notes, full purchase dates, who owes the user money. Every
// amount is in `currency`, like the rest of the snapshot. Royal only, as the
// whole sync is.

enum WebWealth {

    /// A price not updated for this long is dated on its row on the web, so
    /// a gold price typed in months ago is not read as today's.
    static let stalePriceDays = 30

    @MainActor
    static func payload(cards: [BankCard], goals: [SavingsGoal], receivables: [Receivable],
                        holdings: [InvestmentHolding], assets: [PhysicalAsset],
                        debts: [DebtRecord], installments: [CardInstallment],
                        currency: String, now: Date = .now, calendar: Calendar = .current) -> [String: Any] {
        let parts = NetWorth.parts(cards: cards, goals: goals, receivables: receivables,
                                   holdings: holdings, assets: assets, debts: debts,
                                   installments: installments, currency: currency, now: now)
        return [
            "net":         parts.total,
            // What you have, in the parts the page names.
            "cash":        parts.balance,
            "savings":     parts.goals,
            "lent":        parts.receivables,
            "investments": parts.investments,
            "assets":      parts.assets,
            // What you owe: debts and what is owed on credit cards.
            "owed":        parts.liabilities,
            "cardOwed":    parts.cardOwed,
            "holdings":    holdingRows(holdings, currency: currency, now: now, calendar: calendar),
            "things":      thingRows(assets, currency: currency, now: now, calendar: calendar),
        ]
    }

    /// One row per holding still held, largest first.
    @MainActor
    static func holdingRows(_ holdings: [InvestmentHolding], currency: String, now: Date,
                            calendar: Calendar = .current) -> [[String: Any]] {
        let cm = CurrencyManager.shared
        let rows: [(value: Double, row: [String: Any])] = holdings.compactMap { h in
            let s = h.stats()
            guard s.unitsHeld > 1e-9 || s.marketValue >= 0.5 else { return nil }
            let conv = { (v: Double) in cm.convert(v, from: h.currency, to: currency) }
            let value = conv(s.marketValue)
            var row: [String: Any] = [
                "name":  h.name,
                // rawValue: the web names it in its own language.
                "type":  h.type.rawValue,
                "value": value,
                // "Modal": what the units still held cost.
                "cost":  conv(s.costBasis),
                // Everything made on it — price change, sales, interest and
                // dividends — as the Investments header adds it up, so a
                // deposit's interest shows as a gain.
                "gain":  conv(s.totalReturn),
            ]
            if h.type == .gold { row["grams"] = s.unitsHeld }
            if !h.type.priceIsFixed, let at = h.priceUpdatedAt,
               now.timeIntervalSince(at) > Double(stalePriceDays) * 86_400 {
                row["priceDate"] = day(at, calendar)
            }
            return (value, row)
        }
        return rows.sorted { $0.value > $1.value }.map { $0.row }
    }

    /// One row per belonging, largest first.
    @MainActor
    static func thingRows(_ assets: [PhysicalAsset], currency: String, now: Date,
                          calendar: Calendar = .current) -> [[String: Any]] {
        let cm = CurrencyManager.shared
        let rows: [(value: Double, row: [String: Any])] = assets.map { a in
            let conv = { (v: Double) in cm.convert(v, from: a.currency, to: currency) }
            let value = conv(a.value(at: now))
            var row: [String: Any] = [
                "name":  a.name,
                "kind":  a.kind.rawValue,
                "value": value,
                "paid":  conv(a.purchasePrice),
                // The year only: the row says "Dibeli 2023".
                "year":  calendar.component(.year, from: a.purchaseDate),
            ]
            if a.manualValue > 0 {
                // The estimate carries on from the user's figure.
                row["enteredMonth"] = month(a.manualValueDate ?? a.purchaseDate, calendar)
            } else {
                // The trend the asset form states: the yearly rate, and the
                // first year's drop while the thing is still in that year.
                row["ratePct"] = Int(a.effectiveRate)
                let years = now.timeIntervalSince(a.purchaseDate) / (365.25 * 86_400)
                if a.firstYearDrop > 0, years < 1 { row["firstYearDropPct"] = Int(a.firstYearDrop) }
            }
            if let tax = taxKey(a.kind), let set = a.taxDueDate {
                row["tax"] = tax
                row["taxDue"] = day(AssetTaxReminders.nextOccurrence(of: set, onOrAfter: now, cal: calendar),
                                    calendar)
            }
            return (value, row)
        }
        return rows.sorted { $0.value > $1.value }.map { $0.row }
    }

    /// The yearly tax a kind pays, as a key the web words itself: the same
    /// kinds as `AssetKind.taxLabel`.
    static func taxKey(_ kind: AssetKind) -> String? {
        switch kind {
        case .motorcycle, .car: return "stnk"
        case .house, .land:     return "pbb"
        default:                return nil
        }
    }

    /// A calendar day or month on the phone, as text. Not an instant: the
    /// browser reading it may sit in another zone, and a due date must not
    /// move a day.
    static func day(_ d: Date, _ cal: Calendar) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return "\(pad(c.year, 4))-\(pad(c.month, 2))-\(pad(c.day, 2))"
    }

    static func month(_ d: Date, _ cal: Calendar) -> String {
        let c = cal.dateComponents([.year, .month], from: d)
        return "\(pad(c.year, 4))-\(pad(c.month, 2))"
    }

    private static func pad(_ n: Int?, _ width: Int) -> String {
        let s = String(n ?? 0)
        return String(repeating: "0", count: max(width - s.count, 0)) + s
    }
}
