import Foundation

// MARK: - Local Transaction Parser
//
// "Use the simplest tool that solves the problem." Ask DiPo charges a credit and
// a network round trip for every message, including the one its own greeting
// suggests — "beli kopi 25rb dan parkir 5rb". That is a tokenising problem, not
// a language-model problem.
//
// This runs first. When it is confident, the entry is free, instant, and works
// with no signal — which is what makes the voice button worth using, since
// speaking a transaction and waiting on a server is a worse experience than
// typing one. When it is not confident it returns nil and the LLM handles it,
// so credits are spent only on input that actually needs judgement.
//
// The bias is deliberately toward giving up. A wrong local parse silently
// records the wrong number; a missed one merely costs a credit. Every rule
// below is written to fail closed.
enum LocalTxParser {

    struct Result {
        let items: [ParsedItem]
    }

    struct ParsedItem {
        let name: String
        let amount: Double
        let isExpense: Bool
        let category: TxCategory
    }

    // MARK: - Vocabulary

    /// Multipliers written after a number. Order matters when matching: longer
    /// suffixes must be tried first so "ribu" isn't cut short by "rb".
    private static let multipliers: [(token: String, factor: Double)] = [
        ("miliar", 1_000_000_000), ("milyar", 1_000_000_000), ("m", 1_000_000),
        ("juta", 1_000_000), ("jt", 1_000_000),
        ("ribu", 1_000), ("rb", 1_000), ("k", 1_000),
    ]

    /// Words that mean the money came IN. Everything else is treated as
    /// spending, which is the overwhelmingly common case.
    private static let incomeWords: Set<String> = [
        "gaji", "gajian", "salary", "bonus", "thr", "terima", "dapat", "dapet",
        "masuk", "income", "pemasukan", "untung", "profit", "refund", "cashback",
        "hadiah", "gift", "komisi", "fee", "honor", "dividen", "bunga",
    ]

    /// Category keywords. First match wins, so the table is ordered from most
    /// specific to most generic.
    private static let categoryWords: [(TxCategory, [String])] = [
        (.food,      ["makan", "makanan", "minum", "kopi", "coffee", "sarapan", "nasi",
                      "warteg", "resto", "restoran", "cafe", "kafe", "jajan", "snack",
                      "bakso", "mie", "ayam", "gofood", "grabfood", "lunch", "dinner",
                      "breakfast", "food", "drink", "teh", "susu", "roti"]),
        (.transport, ["bensin", "pertamax", "pertalite", "solar", "parkir", "parking",
                      "tol", "grab", "gojek", "gocar", "goride", "ojek", "taksi", "taxi",
                      "busway", "transjakarta", "krl", "mrt", "lrt", "kereta", "angkot",
                      "transport", "bbm", "servis motor", "service motor"]),
        (.bills,     ["listrik", "pln", "token listrik", "air", "pdam", "internet",
                      "wifi", "indihome", "pulsa", "paket data", "netflix", "spotify",
                      "youtube", "langganan", "subscription", "tagihan", "bill",
                      "asuransi", "bpjs", "iuran"]),
        (.health,    ["obat", "apotek", "apotik", "dokter", "rumah sakit", "klinik",
                      "vitamin", "medical", "hospital", "clinic", "gigi", "periksa"]),
        (.travel,    ["hotel", "tiket pesawat", "pesawat", "liburan", "wisata", "travel",
                      "penginapan", "villa", "airbnb", "flight"]),
        (.shopping,  ["beli", "belanja", "baju", "sepatu", "tas", "shopee", "tokopedia",
                      "lazada", "tiktok shop", "olshop", "shopping", "mall"]),
        (.commitment,["kos", "kost", "sewa", "kontrakan", "cicilan", "angsuran",
                      "transfer mom", "transfer ibu", "kirim orang tua", "spp", "kuliah"]),
        (.salary,    ["gaji", "gajian", "salary", "payroll"]),
        (.bonus,     ["bonus", "thr", "tunjangan"]),
        (.freelance, ["freelance", "projek", "proyek", "honor", "komisi"]),
    ]

    /// Words that carry no meaning as a transaction name. Note this strips from
    /// the NAME only — category and income detection both run on the original
    /// text, so removing "beli" or "dapat" here costs no classification signal.
    private static let stopWords: Set<String> = [
        "dan", "and", "lalu", "terus", "sama", "dengan", "buat", "untuk", "di", "ke",
        "dari", "yang", "aku", "saya", "gue", "gw", "tadi", "barusan", "hari", "ini",
        "rp", "idr", "sebesar", "seharga", "harga", "bayar", "spent", "paid", "for",
        // Leading verbs. "Beli Kopi" reads as an action; "Kopi" reads as a
        // ledger line, which is what this ends up being.
        "beli", "dapat", "dapet", "terima", "keluar", "abis", "habis", "udah", "sudah",
        "bought", "buy", "got", "received", "spend", "on",
    ]

    // MARK: - Entry point

    /// Returns nil when the text should go to the language model instead.
    static func parse(_ raw: String) -> Result? {
        let text = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // A question is never a transaction. "berapa pengeluaran saya bulan ini"
        // contains no amount, but neither does a typo — the question check is
        // what keeps genuine queries from being mistaken for a failed parse.
        if looksLikeQuestion(text) { return nil }

        // Split on connectors so "beli kopi 25rb dan parkir 5rb" becomes two
        // entries. Splitting on a bare comma is safe here because Indonesian
        // amounts use "." for thousands.
        // English connectors matter as much as Indonesian ones: the app's own
        // English example is "coffee 25k and parking 5k", and without " and "
        // here that parsed as ONE transaction called "Coffee And Parking".
        let segments = text
            .replacingOccurrences(of: " lalu ", with: " dan ")
            .replacingOccurrences(of: " terus ", with: " dan ")
            .replacingOccurrences(of: " and ", with: " dan ")
            .replacingOccurrences(of: " plus ", with: " dan ")
            .replacingOccurrences(of: ",", with: " dan ")
            .components(separatedBy: " dan ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var items: [ParsedItem] = []
        for segment in segments {
            guard let item = parseSegment(segment, fullText: text) else {
                // One unparseable fragment invalidates the whole message. Half a
                // transaction list is worse than none: the user would have to
                // notice what silently went missing.
                return nil
            }
            items.append(item)
        }

        guard !items.isEmpty, items.count <= 6 else { return nil }
        return Result(items: items)
    }

    // MARK: - Segment parsing

    private static func parseSegment(_ segment: String, fullText: String) -> ParsedItem? {
        guard let (amount, range) = extractAmount(segment) else { return nil }
        // Reject absurd values rather than record them. A parse this far off is
        // more likely a misread than a real transaction.
        guard amount > 0, amount < 1_000_000_000_000 else { return nil }

        var name = segment
        name.removeSubrange(range)
        name = cleanName(name)
        guard !name.isEmpty else { return nil }

        // Income words may sit in a neighbouring clause ("gaji masuk 10jt dan
        // bayar kos 2jt"), so check the segment first and fall back to the
        // whole message only when the segment itself is silent on direction.
        let isIncome = containsIncomeWord(segment)
            || (segments(of: fullText).count == 1 && containsIncomeWord(fullText))

        return ParsedItem(name: titleCase(name),
                          amount: amount,
                          isExpense: !isIncome,
                          category: inferCategory(segment, isIncome: isIncome))
    }

    private static func segments(of text: String) -> [String] {
        text.components(separatedBy: " dan ")
    }

    // MARK: - Amount extraction

    /// Finds the first number plus optional multiplier suffix. Returns the value
    /// and the range it occupied so the caller can strip it from the name.
    private static func extractAmount(_ s: String) -> (Double, Range<String.Index>)? {
        // Number forms accepted: 25000, 25.000, 25,5, 25rb, 2jt, 50k, 1.5jt
        let pattern = #"(\d{1,3}(?:[.\s]\d{3})+|\d+(?:[.,]\d+)?)\s*(miliar|milyar|juta|jt|ribu|rb|k|m)?\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let numRange = Range(match.range(at: 1), in: s),
              let whole = Range(match.range(at: 0), in: s)
        else { return nil }

        let numText = String(s[numRange])
        var suffix = ""
        if match.range(at: 2).location != NSNotFound,
           let r = Range(match.range(at: 2), in: s) {
            suffix = String(s[r])
        }

        guard let base = parseNumber(numText, hasSuffix: !suffix.isEmpty) else { return nil }
        let factor = multipliers.first { $0.token == suffix }?.factor ?? 1
        return (base * factor, whole)
    }

    /// The "." is the crux. In Indonesian "25.000" is twenty-five thousand, but
    /// in "1.5jt" it is a decimal point. The suffix disambiguates: with a
    /// multiplier attached, a dot is decimal; without one, it is grouping.
    private static func parseNumber(_ text: String, hasSuffix: Bool) -> Double? {
        var t = text.replacingOccurrences(of: " ", with: "")
        if hasSuffix {
            t = t.replacingOccurrences(of: ",", with: ".")
            return Double(t)
        }
        // Grouped form: 25.000 / 1.250.000
        if t.contains(".") {
            let parts = t.components(separatedBy: ".")
            let grouped = parts.dropFirst().allSatisfy { $0.count == 3 }
            if parts.count > 1 && grouped { return Double(parts.joined()) }
            return Double(t)                       // plain decimal, e.g. "25.5"
        }
        t = t.replacingOccurrences(of: ",", with: ".")
        return Double(t)
    }

    // MARK: - Classification

    private static func containsIncomeWord(_ s: String) -> Bool {
        let words = tokens(s)
        return words.contains { incomeWords.contains($0) }
    }

    private static func inferCategory(_ s: String, isIncome: Bool) -> TxCategory {
        for (category, keys) in categoryWords {
            // Income text must not land on an expense category and vice versa,
            // or "gaji" would match .commitment through an unrelated keyword.
            if isIncome != category.isIncomeCategory { continue }
            for key in keys where s.contains(key) { return category }
        }
        return isIncome ? .incomeOther : .other
    }

    private static func looksLikeQuestion(_ s: String) -> Bool {
        if s.hasSuffix("?") { return true }
        let openers = ["berapa", "apakah", "gimana", "bagaimana", "kenapa", "mengapa",
                       "kapan", "dimana", "di mana", "siapa", "how much", "how many",
                       "what", "when", "why", "where", "show me", "tampilkan",
                       "analisa", "analisis", "saran", "rekomendasi", "bandingkan"]
        return openers.contains { s.hasPrefix($0 + " ") || s == $0 }
    }

    // MARK: - Name cleanup

    private static func tokens(_ s: String) -> [String] {
        s.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ").map(String.init)
    }

    private static func cleanName(_ s: String) -> String {
        tokens(s)
            .filter { !stopWords.contains($0) && Double($0) == nil }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func titleCase(_ s: String) -> String {
        s.split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

private extension TxCategory {
    /// Whether this category describes money coming in. Used to keep category
    /// inference on the correct side of the ledger.
    var isIncomeCategory: Bool {
        switch self {
        case .salary, .freelance, .business, .bonus, .gift, .incomeOther: return true
        default: return false
        }
    }
}
