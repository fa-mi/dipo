import Foundation

// MARK: - A payment, read from another app's notification
//
// iOS 27 gave Shortcuts a trigger for notifications: "when I receive a
// notification from Livin', GoPay, DANA…". The automation hands DiPo what the
// banner showed (the app, the title, the subtitle, the message) and this
// decides whether it was a payment and, if it was, what it says.
//
// The trigger fires on everything those apps send, and most of it is not
// money: promos, reminders, chat, delivery news, one-time codes. So where
// BankMessageParser reads a message the user chose to hand over, this reads
// whatever arrived and keeps it only when it says money has moved:
//
//   • a one-time code, a password or a "don't share this" is never kept, not
//     even its words. A transfer's OTP carries an amount and a "transfer ke",
//     and otherwise looks exactly like the transfer;
//   • no amount, an offer ("hingga", "s.d.", "klaim"), a payment that failed,
//     waits or is being asked for, a bill reminder: nothing kept;
//   • what is left must say the money moved: "berhasil", "masuk", "kamu
//     bayar", "DB"…
//
// It fails closed, like everything that feeds the review queue. A payment it
// misses is one the user types in; a code it kept would sit in the store and
// in every backup. Nothing here leaves the phone.

enum NotificationTx {

    enum Verdict: Equatable {
        /// Money moved: worth a row in the review queue.
        case payment
        /// A one-time code, a password, a security warning. Dropped whole.
        case secret
        /// No money moved, or not yet: a promo, a reminder, a failed or
        /// pending payment, a balance, a chat.
        case notMoney
    }

    /// The notification as the automation handed it over, trimmed and capped:
    /// a notification can carry a few kilobytes, and nothing that long is one
    /// payment.
    struct Notice: Equatable {
        let app: String
        let title: String
        let subtitle: String
        let body: String

        init(body: String?, title: String? = nil, subtitle: String? = nil, app: String? = nil) {
            func tidy(_ s: String?, _ cap: Int) -> String {
                String((s ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(cap))
            }
            self.app = tidy(app, 60)
            self.title = tidy(title, 200)
            self.subtitle = tidy(subtitle, 200)
            self.body = tidy(body, 1_000)
        }

        /// Title, subtitle and message as one text, each once: some apps
        /// repeat the title in the message, and Shortcuts' Notification may
        /// hold the title already.
        var text: String {
            var parts: [String] = []
            for part in [title, subtitle, body] where !part.isEmpty {
                let lower = part.lowercased()
                if parts.contains(where: { $0.lowercased().contains(lower) }) { continue }
                parts.removeAll { lower.contains($0.lowercased()) }
                parts.append(part)
            }
            return parts.joined(separator: "\n")
        }

        /// What the review row keeps: the banner as it was seen, app first.
        var shown: String {
            [app, text].filter { !$0.isEmpty }.joined(separator: "\n")
        }
    }

    /// What a payment notification says, ready for the review queue.
    struct Reading: Equatable {
        var name: String
        /// Signed, as in `TxRecord`: negative is money out.
        var amount: Double
        var currency: String
        var category: TxCategory
        var accountTail: String?
        /// The bank or wallet behind the app that sent it.
        var appIssuer: String?
        /// A bank or wallet the words name, for when the app says nothing.
        var namedIssuer: String?
    }

    // MARK: Payment or not

    static func verdict(_ notice: Notice) -> Verdict {
        // DiPo's own reminders talk about money too.
        if words(notice.app).contains("dipo") { return .notMoney }
        let text = plain(notice.text)
        if isSecret(text) { return .secret }
        if isNotPayment(text) { return .notMoney }
        return has(movedWords, in: text) ? .payment : .notMoney
    }

    /// A message the user's own automation picked out: a bank's SMS or email,
    /// from a sender the user chose. The same screening, without asking it to
    /// say the money moved, because bank SMS are terse ("BCA: 27/09 DB
    /// Rp50.000,00 QRIS WARKOP"). Codes still never pass: the bank's number
    /// sends its OTPs too, often with the amount they confirm.
    static func screen(_ message: String) -> Verdict {
        let text = plain(message)
        if isSecret(text) { return .secret }
        return isNotPayment(text) ? .notMoney : .payment
    }

    /// No amount, an offer, a reminder, a parcel on its way, or a payment
    /// that isn't done.
    private static func isNotPayment(_ text: String) -> Bool {
        BankMessageParser.firstAmount(in: text) == nil || has(offerWords, in: text)
            || has(reminderWords, in: text) || isDelivery(text)
            || (has(unfinishedWords, in: text) && !isSettledRefund(text))
    }

    /// A one-time code, a password, or the warning that comes with them.
    static func isSecret(_ text: String) -> Bool {
        if has(secretWords, in: text) { return true }
        // "Gunakan kode 123456 untuk transaksi Rp500.000" carries no warning,
        // only a code beside the word for one. Amounts, dates, times, masked
        // accounts, longer numbers and years are not codes.
        guard has(["kode", "kodenya", "code"], in: text) else { return false }
        let rest = text.replacingOccurrences(of: #"(?:rp|idr)\s*\.?\s*[0-9][0-9.,]*"#, with: " ",
                                             options: .regularExpression)
        return rest.range(of: #"(?<![0-9.,/*•\-])\b(?!(?:19|20)[0-9]{2}\b)[0-9]{4,8}\b(?![.,:/\-]?[0-9])"#,
                          options: .regularExpression) != nil
    }

    private static let secretWords = [
        "otp", "one-time password", "one time password", "one-time code", "one time code",
        "kode verifikasi", "verification code", "kode keamanan", "security code",
        "kode login", "login code", "kode masuk", "kode akses", "access code",
        "kode aktivasi", "activation code", "kode rahasia", "secret code", "passcode",
        "password", "kata sandi", "pin", "mpin", "m-pin", "tac",
        "jangan berikan", "jangan beri", "jangan bagikan", "jangan kasih", "jangan sebarkan",
        "jangan beritahu", "jangan beritahukan", "jangan memberikan", "jangan membagikan",
        "jangan informasikan", "rahasiakan", "do not share", "don't share", "dont share", "never share",
    ]

    /// An offer, never a payment: an "up to" figure is never what was paid.
    private static let offerWords = [
        "promo", "diskon", "discount", "hingga", "s.d", "s/d", "sampai dengan", "up to",
        "klaim", "claim", "dapatkan", "raih", "buruan", "jangan lewatkan", "don't miss", "dont miss",
        "berlaku", "valid until", "valid till", "min. belanja", "min belanja", "minimal belanja",
        "min. transaksi", "min transaksi", "minimal transaksi", "min. pembelian", "min pembelian",
        "minimal pembelian", "gratis ongkir", "flash sale", "s&k", "syarat dan ketentuan",
        "terms and conditions", "kode promo", "kode voucher", "promo code", "voucher code",
        "pakai kode", "gunakan kode", "use code", "spesial untukmu", "khusus untukmu",
        "special for you", "just for you", "mulai dari", "mulai rp", "starting from",
        "per bulan", "/bulan", "/bln", "per month", "/month", "bunga 0", "cicilan 0",
    ]

    /// A bill or a statement still to come.
    private static let reminderWords = [
        "jatuh tempo", "due date", "due on", "pengingat", "reminder", "jangan lupa",
        "don't forget", "dont forget", "bayar sebelum", "pay before", "batas waktu",
        "batas pembayaran", "segera bayar", "segera lakukan", "terbit", "e-statement",
        "estatement", "lembar tagihan",
    ]

    /// Not done: failed, waiting, cancelled, asked for, or only promised.
    private static let unfinishedWords = [
        "gagal", "failed", "fail", "batal", "dibatalkan", "pembatalan", "cancelled", "canceled",
        "ditolak", "declined", "rejected", "tertunda", "pending", "menunggu", "waiting",
        "diproses", "sedang diproses", "processing", "kedaluwarsa", "kadaluarsa", "kadaluwarsa",
        "expired", "belum", "tidak cukup", "insufficient", "konfirmasi", "confirm", "selesaikan",
        "lanjutkan", "meminta", "minta", "permintaan", "request", "requested",
        "akan dikembalikan", "akan direfund", "will be refunded", "akan masuk", "will be credited",
        "akan diproses",
    ]

    /// Words that say the money has moved.
    private static let movedWords = [
        "berhasil", "sukses", "success", "successful", "successfully",
        "masuk", "diterima", "menerima", "kamu terima", "anda terima", "received", "bertambah",
        "dikembalikan", "refund", "refunded", "direfund", "credited", "dikredit", "cr", "kredit",
        "keluar", "berkurang", "dibayar", "terbayar", "kamu bayar", "anda bayar", "kamu membayar",
        "anda membayar", "you paid", "paid", "dikirim", "terkirim", "kamu kirim", "anda kirim",
        "dikirimi", "sent", "debited", "didebet", "db", "debet", "debit", "tarik tunai",
        "penarikan", "withdrawal",
    ]

    /// An order on its way: "Pesanan senilai Rp150.000 sudah dikirim" is the
    /// parcel moving, not the money.
    private static func isDelivery(_ text: String) -> Bool {
        has(["kurir", "resi", "dalam perjalanan", "out for delivery", "shipped", "diantar"], in: text)
            || (has(["pesanan", "pesananmu", "order", "paket", "paketmu"], in: text)
                && has(["dikirim", "terkirim"], in: text))
    }

    /// A refund that has arrived, not one being promised after a failure:
    /// "refund … untuk pesanan yang dibatalkan telah masuk" is money in.
    private static func isSettledRefund(_ text: String) -> Bool {
        has(["refund", "refunded", "direfund", "pengembalian dana", "dikembalikan"], in: text)
            && !has(["akan dikembalikan", "akan direfund", "will be refunded", "dalam proses"], in: text)
    }

    // MARK: What it says

    /// The payment a notification tells of, or nil when it tells of none.
    static func read(_ notice: Notice, defaultCurrency: String = "IDR") -> Reading? {
        guard verdict(notice) == .payment,
              let parsed = BankMessageParser.parse(notice.text, defaultCurrency: defaultCurrency)
        else { return nil }
        let text = plain(notice.text)
        let appIssuer = issuer(ofApp: notice.app)
        let kind: AppKind = isMerchantApp(notice.app) ? .merchant
            : appIssuer.map { walletKeys.contains($0) } == true ? .wallet : .other
        let incoming = isIncoming(text, kind: kind, appIssuer: appIssuer)
        let magnitude = abs(parsed.amount)
        let name = self.name(in: notice.text, incoming: incoming) ?? notice.app
        return Reading(
            name: name,
            amount: incoming ? magnitude : -magnitude,
            currency: parsed.currency,
            category: category(of: name, text: text, incoming: incoming, kind: kind),
            accountTail: parsed.accountTail,
            appIssuer: appIssuer,
            namedIssuer: firstIssuer(in: words(text), brands: false))
    }

    private enum AppKind { case wallet, merchant, other }

    /// Which way the money went. A wallet's own top-up is money in. Otherwise
    /// the sentence with the amount speaks first, then the rest, and a word
    /// that says the way ("diterima", "kamu bayar") outranks one that only
    /// names the kind of thing ("pembayaran"), so a shop's "Pembayaran QRIS
    /// Rp15.000 diterima" is money in. In a merchant app the payments are the
    /// shop's takings, money in unless a word says otherwise.
    private static func isIncoming(_ text: String, kind: AppKind, appIssuer: String?) -> Bool {
        if kind == .wallet, let wallet = appIssuer, isOwnTopUp(text, wallet: wallet) { return true }
        let sentence = sentences(of: text).first { BankMessageParser.firstAmount(in: $0) != nil } ?? text
        for scope in [sentence, text] {
            if let way = earlier(strongIn, strongOut, in: scope) { return way }
            if kind != .merchant, let way = earlier(weakIn, weakOut, in: scope) { return way }
        }
        return kind == .merchant
    }

    private static let strongIn = [
        "masuk", "diterima", "menerima", "kamu terima", "anda terima", "received", "you received",
        "bertambah", "dikembalikan", "pengembalian dana", "refund", "refunded", "direfund",
        "credited", "dikredit", "cr", "transfer dari", "trf dari", "dikirimi", "setoran",
        "dikirim ke kamu", "dikirimkan ke kamu", "dikirim kepadamu", "kirim ke kamu", "sent to you",
    ]
    private static let strongOut = [
        "keluar", "berkurang", "kamu bayar", "anda bayar", "kamu membayar", "anda membayar",
        "you paid", "dikirim", "terkirim", "kamu kirim", "anda kirim", "kirim ke", "transfer ke",
        "trf ke", "sent", "debited", "didebet", "db", "tarik tunai", "penarikan", "withdrawal",
        "dipotong", "terpotong",
    ]
    private static let weakIn = ["kredit", "credit", "gaji", "salary", "cashback", "bonus", "hadiah", "dividen"]
    private static let weakOut = [
        "pembayaran", "pembelian", "bayar", "membayar", "beli", "membeli", "belanja", "payment",
        "purchase", "transfer", "trf", "qris", "top up", "topup", "top-up", "isi saldo", "dibayar",
        "paid", "debit", "debet", "angsuran", "cicilan", "tagihan",
    ]

    /// "Top up Rp100.000 berhasil" in GoPay is money arriving in GoPay. Not
    /// when it bought something ("top up pulsa"), nor when it went to another
    /// wallet ("top up OVO", sent from DANA).
    private static func isOwnTopUp(_ text: String, wallet: String) -> Bool {
        guard let r = text.range(of: #"\b(?:top ?up|top-up|isi saldo)\b"#, options: .regularExpression),
              !has(boughtWords, in: text) else { return false }
        guard let next = words(String(text[r.upperBound...])).first,
              let named = brandNames[next] else { return true }
        return named == wallet
    }

    private static let boughtWords = [
        "pulsa", "paket data", "paket internet", "kuota", "game", "token", "listrik", "pln",
        "e-money", "emoney", "e-toll", "etoll", "flazz", "brizzi", "tapcash", "diamond", "voucher",
    ]

    /// Who the money went to, or came from: the words after "ke", "di",
    /// "QRIS" for money out, after "dari" or "oleh" for money in ("ke"
    /// there names the user's own account). Failing that, what the
    /// notification names before its amount: "Pembelian pulsa Rp50.000" is
    /// Pulsa, "Gaji Rp5.000.000 masuk" is Gaji. Status words that follow a
    /// name ("Warung Bu Siti berhasil") are cut.
    static func name(in text: String, incoming: Bool) -> String? {
        let markers = incoming ? [" dari ", " from ", " oleh ", " by "]
            : ["qris", " di ", " at ", " ke ", " to ", " dari ", " from ", "merchant"]
        for marker in markers {
            guard let r = text.range(of: marker, options: .caseInsensitive),
                  let raw = BankMessageParser.firstName(in: String(text[r.upperBound...])) else { continue }
            let kept = raw.split(separator: " ")
                .prefix { !trailingWords.contains($0.lowercased()) }
                .joined(separator: " ")
            if kept.count >= 2 { return kept }
        }
        return lead(in: text)
    }

    private static let trailingWords: Set<String> = [
        "berhasil", "sukses", "success", "successful", "telah", "sudah", "pada", "tgl", "tanggal",
        "via", "pakai", "menggunakan", "dengan", "sebesar", "senilai", "sejumlah", "melalui",
        "lewat", "dari", "ke", "di", "untuk", "for", "on", "with", "using", "is", "was", "has",
        "rp", "idr", "diterima", "masuk", "keluar", "dikirim", "terkirim", "dibayar", "received",
        "sent", "paid",
    ]

    /// Up to three words before the amount, less the ones that only say a
    /// payment happened.
    private static func lead(in text: String) -> String? {
        let clean = text.replacingOccurrences(of: #"(?i)\bterima\s*kasih\b"#, with: " ",
                                              options: .regularExpression)
        guard let sentence = sentences(of: clean).first(where: { BankMessageParser.firstAmount(in: $0) != nil }),
              let amount = sentence.range(of: #"(?:rp|idr)\s*\.?\s*[0-9]"#,
                                          options: [.regularExpression, .caseInsensitive])
        else { return nil }
        var kept = sentence[..<amount.lowerBound]
            .split { !$0.isLetter && !$0.isNumber && $0 != "-" }
            .map(String.init)
            .filter { $0.contains(where: \.isLetter) }
            .suffix(3)
        while let first = kept.first, fillerWords.contains(first.lowercased()) { kept.removeFirst() }
        while let last = kept.last, fillerWords.contains(last.lowercased()) { kept.removeLast() }
        let name = kept.joined(separator: " ")
        guard name.count >= 3 else { return nil }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    private static let fillerWords: Set<String> = [
        "kamu", "anda", "you", "telah", "sudah", "berhasil", "sukses", "sebesar", "senilai",
        "sejumlah", "nominal", "jumlah", "total", "transaksi", "pembayaran", "pembelian", "payment",
        "purchase", "bayar", "beli", "membeli", "membayar", "menerima", "terima", "received", "paid",
        "dana", "uang", "masuk", "keluar", "bertambah", "berkurang", "db", "cr", "of", "the", "for",
    ]

    private static func category(of name: String, text: String, incoming: Bool, kind: AppKind) -> TxCategory {
        guard incoming else { return SmartBudgetManager.suggestCategory(for: name, txType: "Expense") ?? .other }
        if has(["gaji", "salary", "payroll"], in: text) { return .salary }
        return kind == .merchant ? .business : .incomeOther
    }

    // MARK: Which card

    /// Words that name a bank or a wallet, and the key each stands for. Keys
    /// are BankIssuer ids where the bank has one, so a card's chosen bank
    /// matches as it is.
    private static let brandNames: [String: String] = [
        "mandiri": "mandiri", "livin": "mandiri",
        "bri": "bri", "brimo": "bri",
        "bni": "bni", "wondr": "bni",
        "bca": "bca", "mybca": "bca", "klikbca": "bca",
        "bsi": "bsi", "byond": "bsi",
        "btn": "btn",
        "cimb": "cimb", "octo": "cimb",
        "danamon": "danamon",
        "permata": "permata", "permatamobile": "permata",
        "maybank": "maybank", "maybank2u": "maybank", "m2u": "maybank",
        "ocbc": "ocbc", "nyala": "ocbc",
        "mega": "mega",
        "jenius": "jenius", "btpn": "jenius",
        "jago": "jago",
        "seabank": "seabank",
        "allo": "allo",
        "linebank": "linebank",
        "blu": "blu",
        "neo": "neo", "neobank": "neo",
        "dki": "dki", "bjb": "bjb", "jatim": "jatim",
        "superbank": "superbank",
        "gopay": "gopay",
        "ovo": "ovo",
        "dana": "dana",
        "shopeepay": "shopeepay", "spay": "shopeepay",
        "linkaja": "linkaja",
    ]

    /// Brand words that are everyday words too: "dana" is funds ("dana
    /// masuk", a card called Dana Darurat), "mega" is big, "nyala" is on. In
    /// an app's name they can only be the brand; anywhere else they don't count.
    private static let everydayWords: Set<String> = ["dana", "mega", "neo", "nyala"]

    private static let walletKeys: Set<String> = ["gopay", "ovo", "dana", "shopeepay", "linkaja"]

    /// The bank or wallet behind an app, from its name as Shortcuts gives it:
    /// "Livin' by Mandiri", "BRImo", "blu by BCA Digital". A brand leads its
    /// app's name, so the first word that names one wins ("blu", not the BCA
    /// after it). Nil for a shop, or anything whose payments could come from
    /// any card.
    static func issuer(ofApp name: String) -> String? {
        let w = words(name)
        return firstIssuer(in: w, brands: true) ?? brandNames[w.joined()]
    }

    /// The bank or wallet a card is: the wallet chosen for it, the bank chosen
    /// for it, or a bank written into its name, as on cards from before the
    /// bank picker ("Fahmi Aquinas BRI"). A name is read from the end, where
    /// the bank goes; a holder called Mega starts with their own name.
    static func issuer(of card: BankCard) -> String? {
        if card.isDigitalWallet, let key = firstIssuer(in: words(card.walletProvider), brands: true) {
            return key
        }
        if !card.issuerID.isEmpty { return card.issuerID }
        return firstIssuer(in: words(card.holderName).reversed(), brands: false)
    }

    /// The card a payment belongs to.
    ///
    /// The sending app says more than the words: a Livin' notification is
    /// about a Mandiri account, whatever account it names ("transfer ke rek
    /// ****5678" names where the money went). So the app's bank or wallet
    /// picks the cards, an account tail picks among them, and when that
    /// leaves more than one, none: the review queue asks rather than guesses.
    /// An app that is neither (Shopee) leaves it to an account tail, then to
    /// a bank or wallet the message names.
    static func card(for reading: Reading, in cards: [BankCard]) -> BankCard? {
        func endsInTail(_ card: BankCard) -> Bool {
            guard let tail = reading.accountTail else { return false }
            return card.cardNumber.filter(\.isNumber).hasSuffix(tail)
        }
        let candidates: [BankCard]
        if let app = reading.appIssuer {
            candidates = cards.filter { issuer(of: $0) == app }
        } else {
            if let hit = cards.first(where: endsInTail) { return hit }
            guard let named = reading.namedIssuer else { return nil }
            candidates = cards.filter { issuer(of: $0) == named }
        }
        if let hit = candidates.first(where: endsInTail) { return hit }
        return candidates.count == 1 ? candidates[0] : nil
    }

    private static func firstIssuer<S: Sequence>(in words: S, brands: Bool) -> String?
    where S.Element == String {
        for word in words where brands || !everydayWords.contains(word) {
            if let key = brandNames[word] { return key }
        }
        return nil
    }

    /// GoPay Merchant, DANA Bisnis: the shop's side of a wallet.
    private static func isMerchantApp(_ name: String) -> Bool {
        words(name).contains { merchantWords.contains($0) }
    }

    private static let merchantWords: Set<String> = ["merchant", "bisnis", "business", "biz"]

    // MARK: Words

    /// Lowercased words, split on anything that isn't a letter or a digit:
    /// "Livin' by Mandiri" is livin, by, mandiri.
    static func words(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// Lowercased, with the phrases that name a card rather than a movement
    /// taken out: "kartu kredit" is not money in, nor is "terima kasih" a
    /// receipt.
    static func plain(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: #"\b(?:kartu|card)\s+(?:kredit|debit|credit)\b"#, with: "kartu",
                                  options: .regularExpression)
            .replacingOccurrences(of: #"\b(?:credit|debit)\s+card\b"#, with: "card",
                                  options: .regularExpression)
            .replacingOccurrences(of: #"\bterima\s*kasih\b"#, with: " ", options: .regularExpression)
    }

    /// Whether any of `phrases` is in `text` as whole words: "cr" must not
    /// fire inside "credit", nor "otp" inside "hotpot".
    static func has(_ phrases: [String], in text: String) -> Bool {
        firstPosition(of: phrases, in: text) != nil
    }

    private static func firstPosition(of phrases: [String], in text: String) -> String.Index? {
        phrases.compactMap { phrase -> String.Index? in
            // A word edge only where the phrase starts or ends with a word
            // character; "/bulan" starts at the slash.
            func edge(_ c: Character?) -> String { c.map { $0.isLetter || $0.isNumber } == true ? #"\b"# : "" }
            let pattern = edge(phrase.first) + NSRegularExpression.escapedPattern(for: phrase) + edge(phrase.last)
            return text.range(of: pattern, options: .regularExpression)?.lowerBound
        }.min()
    }

    /// True for money in, false for out, nil when neither list is in `text`.
    /// The word that comes first wins. A tie is a longer phrase saying more
    /// than the word it starts with ("dikirim ke kamu" over "dikirim"), and
    /// those are all money in.
    private static func earlier(_ ins: [String], _ outs: [String], in text: String) -> Bool? {
        switch (firstPosition(of: ins, in: text), firstPosition(of: outs, in: text)) {
        case let (i?, o?): return i <= o
        case (.some, nil): return true
        case (nil, .some): return false
        case (nil, nil):   return nil
        }
    }

    /// Sentences and lines. Split after ". ", not at every dot, or "Rp50.000"
    /// would fall in two.
    private static func sentences(of text: String) -> [String] {
        text.replacingOccurrences(of: #"([.!?;])\s+"#, with: "$1\n", options: .regularExpression)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}
