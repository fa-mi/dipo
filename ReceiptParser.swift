// ReceiptParser.swift
// Parses raw OCR text into a structured ReceiptScanResult.
//
// This is the most failure-prone part of the pipeline — receipts are
// chaotic. We solve it with layered heuristics:
//
//   1. Merchant: top-of-receipt + cross-check against merchantMap (which already
//      contains 70+ Indonesian merchants used by SmartBudgetManager).
//   2. Currency: scan for "Rp"/"IDR"/"$"/"USD" markers; fallback to card currency.
//   3. Amount: prioritize lines containing TOTAL/JUMLAH/BAYAR keywords; pick the
//      largest reasonable number. Indonesian receipts use "1.234.567,89" format
//      (dot for thousands, comma for decimal) — must NOT confuse with US format.
//   4. Date: try a list of regex patterns covering Indonesian + ISO + US formats.
//   5. Category: re-use SmartBudgetManager.suggestCategory() for consistency.
//
// All methods are pure (no side effects) so they're trivially unit-testable.

import Foundation

enum ReceiptParser {

    // MARK: - Public API

    /// Parse raw OCR text into a structured result.
    /// - Parameters:
    ///   - rawText: full text returned by Vision (or any OCR engine).
    ///   - fallbackCurrency: currency to use if none is detected in the text.
    ///     Pass the card's currency so a struk Indomaret never gets tagged USD
    ///     just because the card happens to be a USD wallet.
    ///   - fallbackDate: date to use if none is parsed (typically `.now`).
    static func parse(rawText: String,
                      fallbackCurrency: String,
                      fallbackDate: Date = .now) -> ReceiptScanResult {
        // Normalize: collapse whitespace, drop control chars, keep newlines.
        let cleaned = normalize(rawText)
        let lines = cleaned.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)

        let issuer   = extractIssuer(from: lines)
        let merchant = extractMerchant(from: lines, excluding: issuer)
        let currency = extractCurrency(from: cleaned, fallback: fallbackCurrency)
        let amount   = extractAmount(from: lines, currency: currency)
        let date     = extractDate(from: cleaned, fallback: fallbackDate)
        let category = SmartBudgetManager.suggestCategory(for: merchant, txType: "Expense") ?? .other
        let notes    = extractItemsNote(from: lines)

        // Compute confidence based on how many fields succeeded.
        // Each successful field contributes a fraction; missing fields drag it down.
        var confidence: Double = 0
        if !merchant.isEmpty && merchant != loc("receipt.unknown_merchant") { confidence += 0.35 }
        if amount > 0     { confidence += 0.40 }   // Amount is most critical
        let dateParsed = !cleaned.isEmpty && date != fallbackDate
        if dateParsed { confidence += 0.15 }
        if category != .other { confidence += 0.10 }

        // A failed date does not lower the reading — it silently substitutes
        // TODAY, which looks like a real answer. With merchant, amount and
        // category all found, the total still reached exactly 0.85 and earned
        // a "high confidence — looks accurate" badge over a wrong date. Hold
        // it below the high threshold so the sheet opens editable and says so.
        if !dateParsed { confidence = min(confidence, 0.84) }

        return ReceiptScanResult(
            merchantName: merchant.isEmpty ? loc("receipt.unknown_merchant") : merchant,
            amount: amount,
            currency: currency,
            date: date,
            category: category,
            confidence: confidence,
            mode: .vision,
            rawText: cleaned,
            notes: notes,
            issuer: issuer
        )
    }

    // MARK: - Normalize

    private static func normalize(_ text: String) -> String {
        // Replace common OCR artefacts. "O" sometimes recognized as "0" near
        // digits — we leave digits alone since amounts depend on them.
        // Trim each line to remove leading/trailing whitespace.
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\t", with: " ")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    // MARK: - Merchant Extraction

    /// Strategy: receipts usually have the merchant name in the top 5 lines, in
    /// uppercase or title case, often the largest text. We:
    ///   1. Cross-check the first 6 lines against merchantMap (gold standard).
    ///   2. If no match, take the first non-empty line that's mostly letters.
    /// Labels that introduce the party being PAID. On a QRIS or transfer
    /// receipt this is the only authoritative merchant signal — everything
    /// else on the slip belongs to the bank moving the money.
    private static let payeeLabels = [
        "payment to", "paid to", "pay to", "payee", "recipient",
        "merchant name", "merchant", "nama merchant",
        "pembayaran ke", "bayar ke", "penerima", "kepada", "tujuan",
    ]

    /// Labels whose value is about the RAILS, never the shop.
    private static let railLabels = [
        "acquirer", "issuer", "rrn", "ref", "reference", "trace", "terminal",
        "merchant pan", "approval", "batch", "no. kartu", "card number",
        "sumber dana", "source of fund", "metode", "payment method",
    ]

    /// Banks and wallets. These appear on every payment slip — often as a
    /// repeated watermark — and are the single most likely thing to be
    /// mistaken for the shop. `LAUNDRY EXPERT` lost to a `BCA` watermark
    /// because the heuristic below simply took the first wordy line.
    private static let paymentBrands = [
        "bca", "bri", "bni", "mandiri", "cimb", "niaga", "permata", "danamon",
        "ocbc", "panin", "btn", "bsi", "maybank", "jago", "seabank", "blu",
        "qris", "gpn", "visa", "mastercard", "prima", "alto", "artajasa",
    ]

    /// True when the line is nothing but a payment brand — "BCA", "QRIS",
    /// "Bank BCA". A shop whose name merely CONTAINS one of these (say
    /// "Toko Mandiri Jaya") is left alone, since only near-exact matches are
    /// rejected.
    private static func isPaymentBrandOnly(_ line: String) -> Bool {
        let cleaned = line.lowercased()
            .replacingOccurrences(of: "bank", with: " ")
            .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            .trimmingCharacters(in: .whitespaces)
        return paymentBrands.contains(cleaned)
    }

    /// Labels that introduce the bank or wallet that moved the money.
    private static let issuerLabels = [
        "acquirer", "issuer", "penerbit", "bank", "sumber dana",
        "source of fund", "payment method", "metode pembayaran", "dibayar dengan",
    ]

    /// Reads the payment rail off the slip. Tried BEFORE the merchant so its
    /// value can be excluded there — on a QRIS receipt the bank is splashed
    /// across the image as a watermark and is the single likeliest thing to be
    /// mistaken for the shop.
    static func extractIssuer(from lines: [String]) -> String {
        // A labelled value is authoritative.
        for (i, line) in lines.enumerated() {
            let lower = line.lowercased()
            guard issuerLabels.contains(where: { lower.contains($0) }) else { continue }
            if let sep = line.range(of: ":") {
                let tail = String(line[sep.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !tail.isEmpty, tail.count <= 24 { return tail }
            }
            if let label = issuerLabels.first(where: { lower.contains($0) }),
               let r = lower.range(of: label) {
                let tail = String(line[r.upperBound...])
                    .trimmingCharacters(in: CharacterSet(charactersIn: " \t:-"))
                if !tail.isEmpty, tail.count <= 24 { return tail }
            }
            for next in lines.dropFirst(i + 1).prefix(1) {
                let candidate = next.trimmingCharacters(in: .whitespaces)
                if !candidate.isEmpty, candidate.count <= 24 { return candidate }
            }
        }
        // No label: fall back to a brand appearing on its own line. This is
        // what catches a bare watermark, which is exactly the case that
        // poisoned the merchant before.
        for line in lines where isPaymentBrandOnly(line) {
            return line.trimmingCharacters(in: .whitespaces)
        }
        return ""
    }

    private static func extractMerchant(from lines: [String], excluding issuer: String = "") -> String {
        // Whatever the slip itself named as the payment rail is not the shop,
        // whether or not it happens to be in `paymentBrands`.
        let issuerKey = issuer.lowercased().trimmingCharacters(in: .whitespaces)
        func isIssuer(_ s: String) -> Bool {
            guard !issuerKey.isEmpty else { return false }
            return s.lowercased().trimmingCharacters(in: .whitespaces) == issuerKey
        }

        // Pass 0: an explicit "paid to" label anywhere on the slip beats every
        // heuristic below, and is checked across ALL lines rather than the top
        // few — on a QRIS receipt the header is the amount and the bank logo,
        // and the shop name sits well below them.
        for (i, line) in lines.enumerated() {
            let lower = line.lowercased()
            guard payeeLabels.contains(where: { lower.contains($0) }) else { continue }
            guard !railLabels.contains(where: { lower.contains($0) }) else { continue }

            // "Payment to: SHOP" — value on the same line, after the label.
            if let sep = line.range(of: ":") {
                let tail = String(line[sep.upperBound...]).trimmingCharacters(in: .whitespaces)
                if tail.count >= 3, !isPaymentBrandOnly(tail), !isIssuer(tail) { return tail }
            }
            // Same line, no colon — OCR often merges a two-column row into
            // "Payment to JOURDAN LAUNDRY EXPERT".
            if let label = payeeLabels.first(where: { lower.contains($0) }),
               let r = lower.range(of: label) {
                let tail = String(line[r.upperBound...])
                    .trimmingCharacters(in: CharacterSet(charactersIn: " \t:-"))
                if tail.count >= 3, !isPaymentBrandOnly(tail), !isIssuer(tail) { return tail }
            }
            // Otherwise the label is its own line (or a left column) and the
            // value follows. Receipts wrap long names, so take up to two lines.
            var value = ""
            for next in lines.dropFirst(i + 1).prefix(2) {
                let candidate = next.trimmingCharacters(in: .whitespaces)
                guard !candidate.isEmpty else { continue }
                let candLower = candidate.lowercased()
                if payeeLabels.contains(where: { candLower.contains($0) }) { break }
                if railLabels.contains(where: { candLower.contains($0) }) { break }
                if isPaymentBrandOnly(candidate) || isIssuer(candidate) { break }
                // Stop at the next label/amount row rather than swallowing it.
                if candidate.filter({ $0.isNumber }).count > candidate.filter({ $0.isLetter }).count { break }
                value += (value.isEmpty ? "" : " ") + candidate
            }
            if value.count >= 3 { return value }
        }

        let topLines = Array(lines.prefix(6))

        // Pass 1: known merchants. This catches Indomaret/Alfamart/etc. even if
        // they appear lower than line 1 (sometimes there's a logo region first).
        for line in topLines {
            let lower = line.lowercased()
            for entry in SmartBudgetManager.merchantMap {
                for keyword in entry.keywords {
                    if lower.contains(keyword) {
                        // Return the canonical merchant name (Title Case)
                        return keyword.capitalized
                    }
                }
            }
        }

        // Pass 2: heuristic — first line with mostly letters and length 3..40.
        // Skip lines that look like addresses, phone numbers, or NPWP/tax IDs.
        for line in topLines {
            guard line.count >= 3, line.count <= 40 else { continue }
            let letterCount = line.filter { $0.isLetter }.count
            let digitCount  = line.filter { $0.isNumber }.count
            // Reject lines that are mostly digits (phone, NPWP, branch code)
            guard letterCount > digitCount * 2 else { continue }
            // Reject obvious address/contact markers
            let lower = line.lowercased()
            if lower.contains("jl.") || lower.contains("jalan") ||
               lower.contains("telp") || lower.contains("npwp") ||
               lower.contains("www.") || lower.contains("@") {
                continue
            }
            // A bare bank or scheme name is the payment rail, not the shop.
            if isPaymentBrandOnly(line) || isIssuer(line) { continue }
            // Nor is the label of a rail field.
            if railLabels.contains(where: { lower.contains($0) }) { continue }
            return line
        }

        return ""
    }

    // MARK: - Currency Extraction

    /// Detect IDR vs USD from the receipt body. Indonesian receipts almost always
    /// have "Rp" before amounts; USD receipts have "$" or "USD".
    /// We don't try to detect EUR/JPY etc. — out of scope for an Indonesian app.
    private static func extractCurrency(from text: String, fallback: String) -> String {
        let lower = text.lowercased()

        // Strong IDR signals
        if lower.contains("rp ") || lower.contains("rp.") || lower.contains(" idr") ||
           lower.contains("rupiah") {
            return "IDR"
        }
        // Strong USD signals — "$" alone is risky (could appear in random text)
        // so require it adjacent to digits or an explicit "USD".
        if lower.contains(" usd") || lower.contains("us$") {
            return "USD"
        }
        if let _ = text.range(of: #"\$\s?\d"#, options: .regularExpression) {
            return "USD"
        }

        return fallback
    }

    // MARK: - Amount Extraction

    /// Find the total amount. Strategy:
    ///   1. Find lines containing TOTAL/JUMLAH/BAYAR/GRAND markers.
    ///   2. Extract numbers from those lines using format-aware regex.
    ///   3. Return the largest one (because subtotal/discount/tax may also appear).
    ///   4. If no marker found, fall back to the largest number on the receipt
    ///      that fits a plausible expense range.
    private static func extractAmount(from lines: [String], currency: String) -> Double {
        // "total belanja" beats plain "subtotal" — list the strong markers first
        // so we can prefer them when both appear on the same receipt. Strong
        // markers are explicit "this is the final total" wording in either
        // language. Weak markers catch the generic "total" so we still find a
        // value on receipts that don't use the verbose phrasing.
        let strongMarkers = [
            // Bahasa Indonesia
            "total belanja", "total bayar", "total pembayaran", "total harga",
            "grand total", "total akhir",
            // English
            "amount due", "balance due", "total due", "amount paid",
            "you pay", "total to pay",
        ]
        let weakMarkers   = [
            // Bahasa Indonesia
            "total", "jumlah", "bayar", "grand", "tagihan", "subtotal",
            // English (subtotal/total already covered above)
            "amount",
        ]

        var candidatesFromStrong: [Double] = []
        var candidatesFromWeak:   [Double] = []
        var allNumbers: [Double] = []

        for line in lines {
            let lower = line.lowercased()
            let nums = extractNumbers(from: line, currency: currency)

            // Lines that aren't a total: discounts, taxes, change, IDs.
            // Crucial for Indomaret-style receipts that print NPWP and TRXID
            // numbers with the same dotted format as Rupiah amounts — without
            // this filter, an NPWP like 001.337.994.6 gets read as Rp 13.379.946.
            let isExclusion = lower.contains("kembali") || lower.contains("change") ||
                              lower.contains("hemat") || lower.contains("discount") ||
                              lower.contains("diskon") || lower.contains("ppn") ||
                              lower.contains("pajak") || lower.contains("tax") ||
                              lower.contains("voucher") ||
                              // Tax/business IDs
                              lower.contains("npwp") || lower.contains("nip") ||
                              // Transaction / order IDs
                              lower.contains("trxid") || lower.contains("trx id") ||
                              lower.contains("invoice") || lower.contains("faktur") ||
                              // Address / contact lines
                              lower.contains("telp") || lower.contains("phone") ||
                              lower.contains("alamat") || lower.contains("jl.") ||
                              lower.contains("jalan ") ||
                              // Identifier-style lines starting with "no:" / "id "
                              lower.hasPrefix("no:") || lower.hasPrefix("no.") ||
                              lower.hasPrefix("id ") || lower.hasPrefix("id:") ||
                              // Lines that are mostly stars (masked card/account numbers)
                              line.filter({ $0 == "*" }).count >= 5

            if !isExclusion {
                allNumbers.append(contentsOf: nums)
            }

            if isExclusion { continue }

            if strongMarkers.contains(where: lower.contains) {
                candidatesFromStrong.append(contentsOf: nums)
            } else if weakMarkers.contains(where: lower.contains) {
                candidatesFromWeak.append(contentsOf: nums)
            }
        }

        // Plausibility filter — reject unreasonable values.
        // For IDR: 1,000 to 500 million (Rp 1rb – Rp 500jt). Tighter than the
        // old 1B cap so transaction-ID numbers that normalize into the high
        // hundreds of millions get rejected, while still allowing large legit
        // purchases (electronics, appliances, jewelry).
        // For USD: $0.50 to $500k.
        let plausible: (Double) -> Bool = { v in
            if currency == "IDR" {
                return v >= 1_000 && v <= 500_000_000
            } else {
                return v >= 0.5 && v <= 500_000
            }
        }

        // Prefer the strong-marker total over weak markers and over the fallback
        // so "TOTAL BELANJA" always wins against "Subtotal", "Harga Jual", etc.
        if let best = candidatesFromStrong.filter(plausible).max() {
            return best
        }
        if let best = candidatesFromWeak.filter(plausible).max() {
            return best
        }
        return allNumbers.filter(plausible).max() ?? 0
    }

    /// Extract numeric values from a line, handling Indonesian and US formatting.
    ///
    /// Indonesian format: "Rp 1.234.567" or "Rp 1.234.567,89"
    ///   - dot = thousands separator, comma = decimal
    /// US format: "$1,234.56"
    ///   - comma = thousands, dot = decimal
    ///
    /// Heuristic: if the LAST punctuation in the number is comma → ID format.
    /// If it's a dot followed by exactly 2 digits → US format.
    /// Otherwise: if currency is IDR, treat dots as thousands; else US.
    private static func extractNumbers(from line: String, currency: String) -> [Double] {
        // Match runs of digits that may include "." and "," as separators.
        // Require at least one digit. Maximum length keeps us from grabbing
        // serial numbers or transaction IDs as amounts.
        let pattern = #"\d{1,3}(?:[.,]\d{3})*(?:[.,]\d{1,2})?|\d+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsLine = line as NSString
        let matches = regex.matches(in: line, range: NSRange(location: 0, length: nsLine.length))

        return matches.compactMap { m -> Double? in
            let raw = nsLine.substring(with: m.range)
            return parseNumber(raw, currency: currency)
        }
    }

    /// Convert a string like "1.234.567,89" or "1,234.56" to Double, respecting
    /// the receipt's locale conventions.
    private static func parseNumber(_ raw: String, currency: String) -> Double? {
        // No separators → simple parse.
        if !raw.contains(".") && !raw.contains(",") {
            return Double(raw)
        }

        // Detect format from the last separator.
        let lastDot = raw.lastIndex(of: ".")
        let lastComma = raw.lastIndex(of: ",")

        let isIndonesianFormat: Bool = {
            // Comma after the last dot → comma is decimal → ID format.
            if let dot = lastDot, let comma = lastComma {
                return comma > dot
            }
            // Only commas
            if lastComma != nil && lastDot == nil {
                let parts = raw.split(separator: ",")
                // Multiple commas → US-style thousands ("1,234,567")
                if parts.count > 2, parts.dropFirst().allSatisfy({ $0.count == 3 }) {
                    return false
                }
                // Two parts where the trailing group is exactly 3 digits → comma
                // is a thousands separator. No real currency uses 3 fractional
                // digits; in IDR especially there are no subunits at all, so
                // "57,800" must mean 57800 not 57.8. Previously we tiebroke on
                // currency and treated this as decimal for IDR — that produced
                // amounts like Rp 57.8 that failed the plausibility filter.
                if parts.count == 2 && parts[1].count == 3 {
                    return false
                }
                // Otherwise (1-2 digits after comma) treat as decimal.
                return true
            }
            // Only dots → ID thousands ("1.234.567") OR US decimal ("1234.56").
            if lastDot != nil && lastComma == nil {
                let parts = raw.split(separator: ".")
                if parts.count > 2 { return true }                   // 1.234.567 → ID
                if parts.count == 2 {
                    // Trailing group of exactly 3 digits → thousands.
                    // For IDR receipts this is the dominant pattern. For USD,
                    // "1.500" is ambiguous — we still treat as US decimal there.
                    return parts[1].count == 3 && currency == "IDR"
                }
            }
            return currency == "IDR"
        }()

        var normalized = raw
        if isIndonesianFormat {
            // Remove dots (thousands), replace comma (decimal) with dot.
            normalized = normalized.replacingOccurrences(of: ".", with: "")
            normalized = normalized.replacingOccurrences(of: ",", with: ".")
        } else {
            // US: remove commas (thousands); dot is already decimal.
            normalized = normalized.replacingOccurrences(of: ",", with: "")
        }
        return Double(normalized)
    }

    // MARK: - Date Extraction

    // MARK: - Is this even a payment?

    /// Words that only appear where money actually changed hands.
    private static let totalWords = [
        "total", "subtotal", "grand total", "jumlah", "amount", "amount due",
        "total payment", "total bayar", "dibayar", "pembayaran", "payment",
        "tagihan", "bill", "harga", "tunai", "cash", "kembali", "change",
    ]
    private static let receiptWords = [
        "struk", "receipt", "invoice", "nota", "faktur", "qris", "transaksi",
        "transaction", "kasir", "cashier", "npwp", "ppn", "pajak", "tax",
        "rrn", "ref", "approval", "merchant", "terminal", "no. transaksi",
        "berhasil", "successful", "sukses", "order", "pesanan", "struk belanja",
    ]

    /// Does this image look like a payment at all?
    ///
    /// Back Tap fires on whatever is on screen, so the parser gets handed home
    /// screens and app UIs. Those still contain digits, and the amount
    /// extractor will happily find one — a DiPo card screen produced a
    /// confident-looking Rp 1.910.500 that sat one tap away from being saved.
    /// Refusing is the only safe answer: a fabricated transaction is worse
    /// than asking the user to try again.
    ///
    /// Requires a currency marker AND some word that belongs to a payment.
    /// A screen full of numbers with neither is not a receipt.
    static func looksLikeReceipt(_ text: String) -> Bool {
        let lower = text.lowercased()

        // Currency has to sit next to digits — a stray "rp" in prose is not a
        // price, and neither is the "IDR" label on a card list.
        let currencyNearDigits = [
            #"(?:rp|idr)\s?\.?\s?\d"#,
            #"\d\s?(?:rp|idr)\b"#,
            #"\$\s?\d"#,
            #"\busd\s?\d"#,
        ].contains { pattern in
            (try? NSRegularExpression(pattern: pattern))?
                .firstMatch(in: lower, range: NSRange(location: 0, length: (lower as NSString).length)) != nil
        }
        guard currencyNearDigits else { return false }

        return totalWords.contains(where: { lower.contains($0) })
            || receiptWords.contains(where: { lower.contains($0) })
    }

    private static let datePatterns: [(pattern: String, dateFormat: String)] = [
        // 28/04/2026, 28-04-2026, 28.04.2026 (dd/mm/yyyy — Indonesian default)
        (#"\b(\d{1,2})[/.\-](\d{1,2})[/.\-](\d{4})\b"#, "dd/MM/yyyy"),
        // 28/04/26 (dd/mm/yy)
        (#"\b(\d{1,2})[/.\-](\d{1,2})[/.\-](\d{2})\b"#, "dd/MM/yy"),
        // 2026-04-28 (ISO)
        (#"\b(\d{4})-(\d{1,2})-(\d{1,2})\b"#, "yyyy-MM-dd"),
    ]

    /// Month words to month numbers, Indonesian and English, abbreviated and
    /// full. Built as a lookup rather than handed to a `DateFormatter` because
    /// the formatter runs on `en_US_POSIX` for unambiguous numeric parsing,
    /// and that locale cannot read "Mei", "Agu", "Okt" or "Des" at all —
    /// switching its locale to fix that would make the numeric patterns
    /// ambiguous again.
    private static let monthWords: [String: Int] = [
        "jan": 1, "januari": 1, "january": 1,
        "feb": 2, "februari": 2, "february": 2, "pebruari": 2,
        "mar": 3, "maret": 3, "march": 3,
        "apr": 4, "april": 4,
        "mei": 5, "may": 5,
        "jun": 6, "juni": 6, "june": 6,
        "jul": 7, "juli": 7, "july": 7,
        "agu": 8, "ags": 8, "agt": 8, "agustus": 8, "aug": 8, "august": 8,
        "sep": 9, "sept": 9, "september": 9,
        "okt": 10, "oct": 10, "oktober": 10, "october": 10,
        "nov": 11, "november": 11, "nop": 11, "nopember": 11,
        "des": 12, "dec": 12, "desember": 12, "december": 12,
    ]

    /// Dates written with the month spelled out — "12 Sep 2026",
    /// "12 September 2026", "Sep 12, 2026".
    ///
    /// The numeric patterns below miss these entirely, which is how a BCA QRIS
    /// slip reading "12 Sep 2026 20:41:20" silently became today's date.
    private static func extractMonthNameDate(from text: String) -> Date? {
        let patterns = [
            // 12 Sep 2026  /  12 September 2026
            (#"\b(\d{1,2})\s+([A-Za-z]{3,12})\.?\s+(\d{4})\b"#, true),
            // Sep 12, 2026  /  September 12 2026
            (#"\b([A-Za-z]{3,12})\.?\s+(\d{1,2}),?\s+(\d{4})\b"#, false),
        ]
        for (pattern, dayFirst) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = text as NSString
            for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                guard m.numberOfRanges == 4 else { continue }
                let a = ns.substring(with: m.range(at: 1))
                let b = ns.substring(with: m.range(at: 2))
                let y = ns.substring(with: m.range(at: 3))
                let dayStr   = dayFirst ? a : b
                let monthStr = dayFirst ? b : a
                guard let day = Int(dayStr), let year = Int(y),
                      let month = monthWords[monthStr.lowercased()] else { continue }
                var c = DateComponents()
                c.year = year; c.month = month; c.day = day
                c.hour = 12   // midday, so a timezone shift cannot slide the date
                guard let d = Calendar.current.date(from: c) else { continue }
                if isPlausibleReceiptDate(d) { return d }
            }
        }
        return nil
    }

    /// Not in the future beyond clock skew, not older than five years.
    private static func isPlausibleReceiptDate(_ d: Date) -> Bool {
        let now = Date()
        return d <= now.addingTimeInterval(86400)
            && d >= now.addingTimeInterval(-86400 * 365 * 5)
    }

    /// Try multiple date formats. Indonesian receipts use dd/mm/yyyy almost
    /// universally — we try that first. If we ever expand to US receipts we'd
    /// need disambiguation logic for ambiguous dates like 03/04/2026.
    private static func extractDate(from text: String, fallback: Date) -> Date {
        // Spelled-out months first: they are unambiguous, while "12/09" could
        // be either order.
        if let named = extractMonthNameDate(from: text) { return named }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")  // unambiguous parsing

        for (pattern, format) in datePatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = text as NSString
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            for m in matches {
                let raw = ns.substring(with: m.range)
                // Normalize separators so the formatter sees the format's punctuation.
                let normalized = raw
                    .replacingOccurrences(of: ".", with: "/")
                    .replacingOccurrences(of: "-", with: format.contains("-") ? "-" : "/")
                formatter.dateFormat = format.replacingOccurrences(of: "-", with: format.contains("-") ? "-" : "/")
                if let d = formatter.date(from: normalized) {
                    // Sanity check: reject future dates more than 1 day ahead
                    // (clock skew tolerance) and dates older than 5 years.
                    let now = Date()
                    if d <= now.addingTimeInterval(86400) &&
                       d >= now.addingTimeInterval(-86400 * 365 * 5) {
                        return d
                    }
                }
            }
        }
        return fallback
    }

    // MARK: - Items Note

    /// Try to extract item names for the notes field. Strategy: lines that have
    /// a name AND a price next to it (e.g. "Indomie 3.500"). We don't try to be
    /// exhaustive — just pick up to 5 visible items so the user has a reminder
    /// of what they bought when reviewing later.
    ///
    /// Filter aggressively: receipts contain LOTS of non-item text (footers,
    /// member info, points, member benefits, "Terima kasih"). It's better to
    /// return empty than to surface garbage like "N all, Potensi Poin Jika
    /// Anda Member" which adds noise instead of value.
    private static func extractItemsNote(from lines: [String]) -> String {
        var items: [String] = []
        // Match lines like "ITEM NAME ... 1234" or "ITEM NAME 12.345"
        let pattern = #"^([A-Za-z][A-Za-z0-9 .&'\-]{2,30})\s+\d{1,3}(?:[.,]\d{3})*(?:[.,]\d{1,2})?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines) else {
            return ""
        }
        // Aggressive blocklist — any line containing these is NOT an item.
        // We catch:
        //   - Receipt headers/footers (kasir, member, terima kasih)
        //   - Tax/discount/total lines
        //   - Marketing footers ("potensi poin", "anda member", "point jika")
        //   - Personal data (NPWP, phone, address)
        // Blocklist for item-line detection. Anything matching one of these
        // strings is treated as a header/footer/summary, NOT a product item.
        // We deliberately include "total"/"subtotal"/"total harga" here even
        // though they're target lines elsewhere (see extractAmount markers) —
        // this function is the inverse: we want item rows like "PIATTOS 15,400"
        // and explicitly want to skip the summary rows.
        //
        // Keywords are paired between Bahasa Indonesia and English so the same
        // filter works on bilingual / English-only receipts (Starbucks, KFC USA,
        // Whole Foods, etc.).
        let blocklist: [String] = [
            // Summary / totals (skip — handled by extractAmount)
            "total", "subtotal", "grand total", "total harga", "total belanja",
            "amount due", "balance due", "amount", "due",
            // Cash / change
            "kasir", "cashier", "kembali", "change", "tunai", "cash",
            "card", "credit", "debit",
            // Tax / discount / fees
            "ppn", "pajak", "tax", "vat", "gst",
            "diskon", "discount", "promo", "voucher",
            "bayar", "payment", "paid",
            "tip", "gratuity", "service charge", "service fee",
            // Loyalty / membership
            "member", "anggota", "poin", "point", "points",
            "potensi", "potential", "rewards", "loyalty",
            // Greetings / footers
            "terima kasih", "thank you", "thanks", "selamat", "welcome",
            "have a", "please come", "see you", "visit us",
            // Contact / identity
            "npwp", "telp", "phone", "tel:", "fax",
            "alamat", "address", "email", "@", "www.", "http",
            // Payment apps / methods
            "qris", "brimo", "ovo", "gopay", "dana", "shopeepay", "linkaja",
            "paypal", "venmo", "apple pay", "google pay",
            // Date / time / IDs
            "tgl", "jam", "date", "time", "no.", "nomor", "number", "no:",
            "invoice", "receipt #", "order #", "trxid", "trx id",
            // Warranty / expiry
            "expired", "kadaluarsa", "berlaku",
            // Header tokens
            "harga satuan", "qty", "quantity", "unit price", "item price",
            "jumlah",
        ]
        // Items typically have at least one digit (price) and uppercase letters.
        // Reject lines that are nearly all letters (likely sentences/footers).
        for line in lines {
            let lower = line.lowercased()
            guard !blocklist.contains(where: lower.contains) else { continue }
            
            let ns = line as NSString
            guard let m = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
                  m.numberOfRanges > 1 else { continue }
            
            let name = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            // Reject overly short names ("N", "PT", random codes)
            guard name.count >= 4 else { continue }
            // Reject if the name has too many words that look like a full sentence
            // (e.g. "Potensi Poin Jika Anda Member") — items are usually 1-4 words.
            let wordCount = name.split(separator: " ").count
            guard wordCount <= 5 else { continue }
            
            items.append(name)
            if items.count >= 5 { break }
        }
        return items.joined(separator: ", ")
    }
}
