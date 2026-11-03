import Foundation

/// The sentences under Statistics' big number: how this period's spending
/// compares with the last, and today against a typical day. They replace a
/// tinted "↑ 60% vs last period" pill and a strip of four icon figures.
enum StatsLines {
    /// "12% less than last period", or more. Nil without a comparison, or
    /// when the two are within a percent of each other.
    static func comparison(_ change: Double?) -> String? {
        guard let c = change, abs(c) >= 1 else { return nil }
        let pct = String(format: "%.0f%%", abs(c))
        return String(format: loc(c < 0 ? "stats.vs_less" : "stats.vs_more"), pct)
    }

    /// "Today Rp 45.000 · a typical day Rp 120.000". Only today when there is
    /// no typical day yet; nil when there is neither.
    static func days(today: Double, typical: Double, money: (Double) -> String) -> String? {
        if typical >= 0.5 { return String(format: loc("stats.day_line"), money(today), money(typical)) }
        return today >= 0.5 ? String(format: loc("stats.today_line"), money(today)) : nil
    }
}
