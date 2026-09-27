import Foundation

// MARK: - Reading a bank message
//
// Indonesian banks and wallets each write their notifications differently, and
// they change them without telling anyone. A parser built as one regex per bank
// is a parser that breaks quietly, one bank at a time, and the user finds out
// months later when a category looks wrong.
//
// So this reads the SHAPE they share rather than any particular format:
//
//     BCA: 27/09 DB Rp50.000,00 QRIS WARKOP PAK BUDI
//     Trx Rek. xxxx0969: Transfer IBNK ke BUDI Rp. 250000.00 27/09/26 21:22:13
//     DANA: Pembayaran Rp15.000 berhasil di Tokopedia
//
// An amount with a currency in front of it, a word that says which way the
// money went, a counterparty, sometimes a masked account tail and a timestamp.
// Everything is optional except the amount: without that there is nothing worth
// queueing, and a row with a guessed amount is worse than no row.

struct ParsedBankMessage: Equatable {
    var merchant: String
    /// Signed the way `TxRecord` is: negative is money out.
    var amount: Double
    var currency: String
    var date: Date
    /// The last four digits of whatever account the message named.
    var accountTail: String?
    /// A bank or wallet name found in the text, lowercased.
    var issuerHint: String?
}

enum BankMessageParser {

    // Words that decide direction. Money going out is the default: a
    // notification is far more often a purchase than a deposit, and being wrong
    // in the rarer direction costs one tap in a queue the user is reading anyway.
    private static let outWords = [
        "db", "debet", "debit", "pembayaran", "pembelian", "bayar", "belanja",
        "transfer ke", "trf ke", "kirim ke", "tarik", "penarikan", "top up",
        "topup", "purchase", "payment", "withdrawal", "qris",
    ]
    private static let inWords = [
        "cr", "kredit", "credit", "masuk", "diterima", "received", "refund",
        "setoran", "transfer dari", "trf dari", "gaji", "salary", "cashback",
    ]

    private static let issuers = [
        "bca", "bri", "brimo", "mandiri", "livin", "bni", "bsi", "btn", "cimb",
        "permata", "danamon", "maybank", "ocbc", "panin", "jago", "seabank",
        "blu", "jenius", "neo", "allo", "superbank",
        "ovo", "dana", "gopay", "shopeepay", "linkaja", "qris",
    ]

    /// Nil when there is no amount to be found — the one thing worth refusing on.
    static func parse(_ text: String, defaultCurrency: String = "IDR",
                      now: Date = .now) -> ParsedBankMessage? {
        guard let amount = firstAmount(in: text) else { return nil }
        let lower = text.lowercased()
        let outgoing = direction(lower)

        return ParsedBankMessage(
            merchant: merchant(in: text),
            amount: outgoing ? -amount : amount,
            currency: currency(in: lower, fallback: defaultCurrency),
            date: timestamp(in: text, now: now) ?? now,
            accountTail: accountTail(in: text),
            issuerHint: issuers.first { lower.contains($0) }
        )
    }

    // MARK: Amount

    /// The first `Rp`/`IDR` figure in the message.
    ///
    /// Both separator conventions turn up, sometimes in the same bank's
    /// messages: `50.000,00` and `50,000.00`. The rule that settles it without
    /// guessing per bank: whichever separator comes LAST is the decimal point,
    /// and it is only a decimal point if exactly two digits follow it.
    static func firstAmount(in text: String) -> Double? {
        let pattern = #"(?:rp|idr)\s*\.?\s*([0-9][0-9.,]*)"#
        guard let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive])
        else { return nil }
        let raw = text[range]
            .replacingOccurrences(of: #"(?i)(rp|idr)\s*\.?\s*"#, with: "",
                                  options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return number(from: raw)
    }

    static func number(from raw: String) -> Double? {
        var body = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".,"))
        guard !body.isEmpty else { return nil }

        let lastDot = body.lastIndex(of: ".")
        let lastComma = body.lastIndex(of: ",")
        // The separator nearest the end is the candidate decimal point.
        let decimalSep: Character?
        switch (lastDot, lastComma) {
        case let (d?, c?): decimalSep = d > c ? "." : ","
        case (_?, nil):    decimalSep = "."
        case (nil, _?):    decimalSep = ","
        default:           decimalSep = nil
        }

        if let sep = decimalSep, let idx = body.lastIndex(of: sep) {
            let decimals = body.distance(from: body.index(after: idx), to: body.endIndex)
            if decimals == 2 || decimals == 1 {
                // A real decimal part: drop every other separator, keep this one.
                let whole = body[body.startIndex..<idx].filter(\.isNumber)
                let frac = body[body.index(after: idx)...].filter(\.isNumber)
                return Double("\(whole).\(frac)")
            }
        }
        // No decimal part — every separator was grouping.
        body = body.filter(\.isNumber)
        return Double(body)
    }

    // MARK: The rest

    private static func direction(_ lower: String) -> Bool {
        // An explicit "money in" word wins; otherwise treat it as spending.
        if inWords.contains(where: { word(word: $0, in: lower) }) { return false }
        if outWords.contains(where: { word(word: $0, in: lower) }) { return true }
        return true
    }

    /// Whole-word match, so "cr" does not fire inside "credit card" and "db"
    /// does not fire inside a merchant called "DBest".
    private static func word(word: String, in haystack: String) -> Bool {
        haystack.range(of: "\\b\(NSRegularExpression.escapedPattern(for: word))\\b",
                       options: .regularExpression) != nil
    }

    private static func currency(in lower: String, fallback: String) -> String {
        if lower.contains("usd") || lower.contains("$") { return "USD" }
        if lower.contains("rp") || lower.contains("idr") { return "IDR" }
        return fallback
    }

    /// Who the money went to. Tried in order of how sure each marker is.
    static func merchant(in text: String) -> String {
        let markers = ["qris", " di ", " at ", " ke ", " to ", " dari ", " from ", "merchant"]
        let lower = text.lowercased()
        for marker in markers {
            guard let r = lower.range(of: marker) else { continue }
            let tail = String(text[r.upperBound...])
            if let name = firstName(in: tail) { return name }
        }
        // Nothing marked it: the longest run of capitals is usually the name,
        // since banks shout merchant names and nothing else.
        return longestCapsRun(in: text) ?? ""
    }

    /// Words up to the next separator, with amounts, dates and bank names
    /// dropped — those sit next to the name often enough to be picked up.
    private static func firstName(in tail: String) -> String? {
        let stop = CharacterSet(charactersIn: ",.;:\n\r")
        let chunk = tail.components(separatedBy: stop).first ?? tail
        let cleaned = chunk
            .replacingOccurrences(of: #"(?i)(rp|idr)\s*\.?\s*[0-9][0-9.,]*"#, with: "",
                                  options: .regularExpression)
            .replacingOccurrences(of: #"[0-9]{1,2}[/-][0-9]{1,2}([/-][0-9]{2,4})?"#, with: "",
                                  options: .regularExpression)
            .replacingOccurrences(of: #"[0-9]{1,2}:[0-9]{2}(:[0-9]{2})?"#, with: "",
                                  options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        // A bare "Rp" or "IDR" often survives the amount strip, sitting at the
        // end of the name like a typo.
        let words = cleaned.split(separator: " ")
            .filter { !["rp", "rp.", "idr"].contains($0.lowercased()) }
            .prefix(4)
            .joined(separator: " ")
        let name = words.trimmingCharacters(in: .whitespaces)
        return name.count >= 3 ? name : nil
    }

    private static func longestCapsRun(in text: String) -> String? {
        let matches = text.ranges(of: #"[A-Z][A-Z .]{2,}"#, options: .regularExpression)
            .map { text[$0].trimmingCharacters(in: .whitespaces) }
            .filter { !issuers.contains($0.lowercased()) }
        return matches.max { $0.count < $1.count }
    }

    /// A masked account or card tail: "xxxx0969", "**0969", "Rek. ...0969".
    static func accountTail(in text: String) -> String? {
        let pattern = #"(?i)(?:[x*.•]{2,}|rek\.?\s*|a/c\s*|kartu\s*)\s*([0-9]{4})\b"#
        guard let r = text.range(of: pattern, options: .regularExpression) else { return nil }
        return String(text[r].suffix(4))
    }

    /// dd/MM, dd/MM/yy or dd/MM/yyyy, with an optional clock after it.
    static func timestamp(in text: String, now: Date = .now) -> Date? {
        let pattern = #"([0-9]{1,2})[/-]([0-9]{1,2})(?:[/-]([0-9]{2,4}))?(?:\s+([0-9]{1,2}):([0-9]{2}))?"#
        guard let r = text.range(of: pattern, options: .regularExpression) else { return nil }
        let parts = text[r].split(whereSeparator: { "/-: ".contains($0) }).map(String.init)
        guard parts.count >= 2, let day = Int(parts[0]), let month = Int(parts[1]),
              (1...31).contains(day), (1...12).contains(month) else { return nil }

        let cal = Calendar.current
        var comps = cal.dateComponents([.year], from: now)
        comps.day = day
        comps.month = month
        if parts.count >= 3, let y = Int(parts[2]), parts[2].count >= 2 {
            comps.year = parts[2].count == 2 ? 2000 + y : y
        }
        if parts.count >= 5, let h = Int(parts[3]), let m = Int(parts[4]) {
            comps.hour = h; comps.minute = m
        }
        guard let date = cal.date(from: comps) else { return nil }
        // A message cannot describe next week. Without a year in the text, a
        // date after today means it belongs to the year before.
        if date > now, parts.count < 3 {
            return cal.date(byAdding: .year, value: -1, to: date)
        }
        return date
    }

    // MARK: Which card

    /// The card the message is about: its tail first, the bank's name second.
    /// Nil when neither says — the queue asks the user rather than guessing,
    /// because putting a purchase on the wrong card is worse than not filing it.
    static func matchCard(_ parsed: ParsedBankMessage, cards: [BankCard]) -> BankCard? {
        if let tail = parsed.accountTail,
           let hit = cards.first(where: { $0.cardNumber.filter(\.isNumber).hasSuffix(tail) }) {
            return hit
        }
        guard let issuer = parsed.issuerHint else { return nil }
        return cards.first {
            $0.issuerID.lowercased() == issuer
                || $0.walletProvider.lowercased().contains(issuer)
                || $0.holderName.lowercased().contains(issuer)
        }
    }
}

private extension String {
    /// Every range matching a pattern, oldest-API style so this stays readable.
    func ranges(of pattern: String, options: String.CompareOptions) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        var start = startIndex
        while start < endIndex,
              let r = range(of: pattern, options: options, range: start..<endIndex) {
            out.append(r)
            start = r.upperBound
        }
        return out
    }
}
