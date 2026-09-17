import Foundation
import SwiftData

// MARK: - Price Service
//
// Refreshes the cached quote on auto-priced holdings. Kept deliberately small
// and direct — it reads two free, no-key endpoints the app can call itself:
//
//   • Crypto  → CoinGecko simple/price (real-time, IDR or USD).
//   • Stocks  → Yahoo Finance chart (IDX tickers, delayed ~15 min).
//
// Everything else (gold, reksadana, bonds, deposits) is user-maintained, so it
// is skipped here. A failed fetch changes nothing — the manual price stands —
// so the feature works offline and never shows a wrong number because a feed
// blinked. A Cloudflare Worker cache can front these later without touching the
// call sites; only `quote(for:)` would change.

@MainActor
enum PriceService {

    struct Quote { let price: Double; let prevClose: Double }

    /// Refresh every auto-priced holding that has a symbol. Returns how many were
    /// actually updated, so the UI can say "nothing to refresh" honestly.
    @discardableResult
    static func refresh(_ holdings: [InvestmentHolding], context: ModelContext) async -> Int {
        var updated = 0
        for h in holdings where h.type.supportsAutoPrice && !h.manualPrice
                              && !h.symbol.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let q = await quote(for: h) else { continue }
            // Keep the reported previous close when the feed gives one, else fall
            // back to the last price we held so "today" still means something.
            h.prevClose = q.prevClose > 0 ? q.prevClose : (h.lastPrice > 0 ? h.lastPrice : q.price)
            h.lastPrice = q.price
            h.priceUpdatedAt = .now
            updated += 1
        }
        if updated > 0 { try? context.save() }
        return updated
    }

    private static func quote(for h: InvestmentHolding) async -> Quote? {
        switch h.type {
        case .crypto: return await crypto(id: h.symbol, currency: h.currency)
        case .stock:  return await stock(symbol: h.symbol)
        default:      return nil
        }
    }

    // MARK: CoinGecko

    private static func crypto(id: String, currency: String) async -> Quote? {
        let vs = currency.lowercased()
        let coin = id.lowercased().trimmingCharacters(in: .whitespaces)
        guard var c = URLComponents(string: "https://api.coingecko.com/api/v3/simple/price") else { return nil }
        c.queryItems = [
            .init(name: "ids", value: coin),
            .init(name: "vs_currencies", value: vs),
            .init(name: "include_24hr_change", value: "true"),
        ]
        guard let url = c.url,
              let obj = await getJSON(url) as? [String: Any],
              let node = obj[coin] as? [String: Any],
              let price = (node[vs] as? NSNumber)?.doubleValue, price > 0
        else { return nil }
        // prevClose from the 24h % change: price = prev × (1 + change/100).
        let change = (node["\(vs)_24h_change"] as? NSNumber)?.doubleValue ?? 0
        let prev = change != -100 ? price / (1 + change / 100) : price
        return Quote(price: price, prevClose: prev)
    }

    // MARK: Yahoo Finance (IDX)

    private static func stock(symbol raw: String) async -> Quote? {
        let s = raw.trimmingCharacters(in: .whitespaces).uppercased()
        // IDX tickers need the ".JK" suffix; leave any explicit market alone.
        let ticker = s.contains(".") ? s : "\(s).JK"
        guard let url = URL(string:
            "https://query1.finance.yahoo.com/v8/finance/chart/\(ticker)?interval=1d&range=1d"),
              let obj = await getJSON(url) as? [String: Any],
              let chart = obj["chart"] as? [String: Any],
              let results = chart["result"] as? [[String: Any]],
              let meta = results.first?["meta"] as? [String: Any],
              let price = (meta["regularMarketPrice"] as? NSNumber)?.doubleValue, price > 0
        else { return nil }
        let prev = (meta["previousClose"] as? NSNumber)?.doubleValue
                ?? (meta["chartPreviousClose"] as? NSNumber)?.doubleValue ?? 0
        return Quote(price: price, prevClose: prev)
    }

    // MARK: Shared

    private static func getJSON(_ url: URL) async -> Any? {
        var req = URLRequest(url: url, timeoutInterval: 12)
        // Some feeds reject the default URLSession agent; a browser-ish one is
        // tolerated and keeps the request from being 403'd.
        req.setValue("Mozilla/5.0 (DiPo iOS)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            return nil
        }
    }
}
