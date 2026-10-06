import Foundation
import SwiftData

// MARK: - Price Service
//
// Refreshes the cached quote on auto-priced holdings. Kept deliberately small
// and direct — it reads two free, no-key endpoints the app can call itself:
//
//   • Crypto  → CoinGecko simple/price (real-time, IDR or USD).
//   • Stocks  → Yahoo Finance chart (IDX and US tickers, delayed ~15 min).
//
//   • Gold    → Pegadaian's Tabungan Emas price, via the Worker only (it reads
//               Pegadaian's page; there is no API to call from the phone).
//
// Everything else (reksadana, bonds, deposits) is user-maintained, so it is
// skipped here. A failed fetch changes nothing — the manual price stands —
// so the feature works offline and never shows a wrong number because a feed
// blinked. A Cloudflare Worker cache can front these later without touching the
// call sites; only `quote(for:)` would change.

@MainActor
enum PriceService {

    struct Quote { let price: Double; let prevClose: Double }

    /// What a refresh actually did. `checked` counts holdings we got a quote for;
    /// `changed` counts the ones whose price genuinely moved. They differ often —
    /// outside market hours a successful fetch returns the same last price — and
    /// reporting only `checked` made the UI claim an update that never happened.
    struct Outcome {
        var checked = 0
        var changed = 0
    }

    /// Refresh every auto-priced holding that has a symbol.
    ///
    /// One request to the Worker covers the whole portfolio and is served from
    /// the edge cache, so refreshing costs the upstreams almost nothing however
    /// many people do it. Anything the Worker doesn't answer for falls back to
    /// the direct call below — a Worker mid-deploy shouldn't mean no prices.
    @discardableResult
    static func refresh(_ holdings: [InvestmentHolding], context: ModelContext) async -> Outcome {
        var out = Outcome()
        let targets = holdings.filter(\.isAutoPriced)
        guard !targets.isEmpty else { return out }

        var quotes = await workerQuotes(for: targets)
        for h in targets where h.type != .gold && quotes[cacheKey(for: h)] == nil {
            if let q = await quote(for: h) { quotes[cacheKey(for: h)] = q }
        }
        // Gold is priced from the feeds its source needs: a bar from its own
        // brand when the Worker has it, else from Pegadaian's; jewellery from
        // Pegadaian's by purity.
        var goldQuotes: [String: Quote] = [:]
        for sym in Set(targets.flatMap(\.goldSource.requestSymbols)) {
            if let q = quotes[goldKey(sym)] { goldQuotes[sym] = q }
        }
        GoldPricing.rememberLiveBrands(Set(goldQuotes.keys))

        for h in targets {
            let q: Quote?
            if h.type == .gold {
                q = GoldPricing.price(for: h.goldSource, quotes: goldQuotes)
                    .map { Quote(price: $0.price, prevClose: $0.prevClose) }
            } else {
                q = quotes[cacheKey(for: h)]
            }
            guard let q else { continue }
            out.checked += 1
            // Compare before overwriting — a hundredth of a rupiah is noise.
            if abs(q.price - h.lastPrice) > 0.005 { out.changed += 1 }
            // Keep the reported previous close when the feed gives one, else fall
            // back to the last price we held so "today" still means something.
            h.prevClose = q.prevClose > 0 ? q.prevClose : (h.lastPrice > 0 ? h.lastPrice : q.price)
            h.lastPrice = q.price
            h.pushPrice(q.price)
            h.priceUpdatedAt = .now
        }
        // Even an unchanged price moves `priceUpdatedAt`, so save on any check.
        if out.checked > 0 { try? context.save() }
        return out
    }

    // MARK: Worker (cached, batched)

    private static let pricesURL =
        "https://dipo-receipt-scanner.fahmi-aquinas.workers.dev/api/prices"

    /// Must match the key the Worker builds, or every quote looks like a miss.
    private static func feedKind(_ h: InvestmentHolding) -> String {
        switch h.type {
        case .crypto: return "crypto"
        case .gold:   return "gold"
        default:      return "stock"
        }
    }

    private static func goldKey(_ symbol: String) -> String { "gold:\(symbol):idr" }

    private static func cacheKey(for h: InvestmentHolding) -> String {
        let kind = feedKind(h)
        return "\(kind):\(h.symbol.trimmingCharacters(in: .whitespaces).lowercased()):\(h.currency.lowercased())"
    }

    /// One round trip for the whole portfolio. Returns whatever came back; a
    /// symbol the Worker couldn't price is simply absent, never zero.
    private static func workerQuotes(for holdings: [InvestmentHolding]) async -> [String: Quote] {
        guard let url = URL(string: pricesURL) else { return [:] }
        var items: [[String: String]] = holdings.filter { $0.type != .gold }.map {
            ["type": feedKind($0),
             "symbol": $0.symbol.trimmingCharacters(in: .whitespaces),
             "currency": $0.currency]
        }
        // One item per gold feed, however many holdings share it.
        for sym in Set(holdings.flatMap(\.goldSource.requestSymbols)).sorted() {
            items.append(["type": "gold", "symbol": sym, "currency": "IDR"])
        }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (field, value) in await WorkerAuth.headers() {
            req.setValue(value, forHTTPHeaderField: field)
        }
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["items": items])

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let prices = obj["prices"] as? [String: Any]
            else { return [:] }

            var out: [String: Quote] = [:]
            for (key, value) in prices {
                guard let node = value as? [String: Any],
                      let price = (node["price"] as? NSNumber)?.doubleValue, price > 0
                else { continue }
                let prev = (node["prevClose"] as? NSNumber)?.doubleValue ?? 0
                out[key] = Quote(price: price, prevClose: prev)
            }
            return out
        } catch {
            return [:]
        }
    }

    // MARK: Direct (fallback)

    private static func quote(for h: InvestmentHolding) async -> Quote? {
        switch h.type {
        case .crypto: return await crypto(id: h.symbol, currency: h.currency)
        case .stock:  return await stock(symbol: h.symbol, currency: h.currency)
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

    // MARK: Yahoo Finance (IDX, US)

    private static func stock(symbol raw: String, currency: String) async -> Quote? {
        // The holding's currency picks the market: IDR → "BBCA.JK", USD → "AAPL".
        let ticker = StockMarket.yahooTicker(symbol: raw, currency: currency)
        guard let url = URL(string:
            "https://query1.finance.yahoo.com/v8/finance/chart/\(ticker)?interval=1d&range=1d"),
              let obj = await getJSON(url) as? [String: Any],
              let chart = obj["chart"] as? [String: Any],
              let results = chart["result"] as? [[String: Any]],
              let meta = results.first?["meta"] as? [String: Any],
              let price = (meta["regularMarketPrice"] as? NSNumber)?.doubleValue, price > 0
        else { return nil }
        // A quote in another currency than the holding's would be stored as if
        // it were — a $366 share read as Rp366. Refuse it; the price stands.
        if let quoted = meta["currency"] as? String, quoted.uppercased() != currency.uppercased() {
            return nil
        }
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
