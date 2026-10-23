import XCTest
import SwiftData
@testable import DiPo

/// What a Shortcuts automation on bank and wallet notifications hands DiPo,
/// and what DiPo keeps of it. The trigger fires on everything those apps send,
/// so most of these are about what must NOT reach the review queue: a code
/// never, a promo or a reminder not as a payment.
///
/// The words are the shapes Indonesian banks and wallets write in. Real
/// notifications that turn up misread belong here.
@MainActor
final class NotificationTxTests: XCTestCase {

    private func read(_ body: String, title: String = "", app: String) -> NotificationTx.Reading? {
        NotificationTx.read(NotificationTx.Notice(body: body, title: title, app: app))
    }

    private func verdict(_ body: String, title: String = "", app: String = "") -> NotificationTx.Verdict {
        NotificationTx.verdict(NotificationTx.Notice(body: body, title: title, app: app))
    }

    // MARK: Payments

    func testPaymentsOut() throws {
        let cases: [(app: String, title: String, body: String, amount: Double, name: String)] = [
            ("GoPay", "Pembayaran berhasil", "Kamu bayar Rp25.000 ke Kopi Kenangan pakai GoPay.", -25_000, "Kopi Kenangan"),
            ("DANA", "Pembayaran Berhasil", "Pembayaran Rp15.000 berhasil di Tokopedia", -15_000, "Tokopedia"),
            ("ShopeePay", "Pembayaran Berhasil", "Pembayaran sebesar Rp45.000 di Toko Sinar Jaya telah berhasil.", -45_000, "Toko Sinar Jaya"),
            ("Livin' by Mandiri", "Transaksi Berhasil", "Transfer ke BUDI SANTOSO sebesar Rp250.000 berhasil.", -250_000, "BUDI SANTOSO"),
            ("BRImo", "Transaksi Berhasil", "Transfer Rp100.000 ke SITI AMINAH berhasil. No. Ref 123456789012", -100_000, "SITI AMINAH"),
            ("Jago", "", "Kamu bayar Rp50.000 ke Indomaret pakai Kantong Utama", -50_000, "Indomaret"),
            ("myBCA", "", "BCA: 27/09 DB Rp50.000,00 QRIS WARKOP PAK BUDI", -50_000, "WARKOP PAK BUDI"),
            ("DANA", "", "Pembayaran QRIS Rp12.000 di Warung Bu Siti berhasil", -12_000, "Warung Bu Siti"),
            ("Jenius", "Payment successful", "You paid IDR 75,000 to Starbucks", -75_000, "Starbucks"),
            ("OVO", "Transfer Berhasil", "Rp50.000 berhasil dikirim ke BUDI", -50_000, "BUDI"),
        ]
        for c in cases {
            let r = try XCTUnwrap(read(c.body, title: c.title, app: c.app), c.body)
            XCTAssertEqual(r.amount, c.amount, c.body)
            XCTAssertEqual(r.name, c.name, c.body)
            XCTAssertEqual(r.currency, "IDR")
        }
    }

    /// With no "ke" or "di" to name a payee, the words before the amount say
    /// what was bought.
    func testWhatWasBoughtNamesThePayment() throws {
        XCTAssertEqual(read("Pembelian pulsa Rp50.000 untuk 0812xxxx5678 berhasil", app: "DANA")?.name, "Pulsa")
        XCTAssertEqual(read("Pembelian Token PLN Rp100.000 berhasil. Token: 1234-5678-9012-3456-7890",
                            app: "DANA")?.name, "Token PLN")
        XCTAssertEqual(read("Pembayaran tagihan PLN Rp150.000 berhasil", app: "Livin' by Mandiri")?.name,
                       "Tagihan PLN")
        XCTAssertEqual(read("Pembayaran Angsuran Kredit Rp850.000 berhasil", app: "BRImo")?.name,
                       "Angsuran Kredit")
        // Nothing to go by: the app that sent it, never a blank row.
        XCTAssertEqual(read("Terima kasih, pembayaran Rp50.000 berhasil", app: "OVO")?.name, "OVO")
        XCTAssertEqual(read("Pembayaran Rp123.456 untuk pesanan 231023ABCDEF berhasil.",
                            title: "Pembayaran Berhasil", app: "Shopee")?.name, "Shopee")
    }

    func testMoneyIn() throws {
        let cases: [(app: String, title: String, body: String, amount: Double, name: String)] = [
            ("DANA", "Dana Masuk", "Kamu menerima Rp50.000 dari BUDI SANTOSO", 50_000, "BUDI SANTOSO"),
            ("Jago", "", "Uang masuk Rp1.000.000 dari BUDI ke Kantong Utama", 1_000_000, "BUDI"),
            ("GoPay", "", "Kamu terima Rp50.000 dari Siti", 50_000, "Siti"),
            ("OVO", "", "Rp50.000 dikirim ke kamu oleh BUDI", 50_000, "BUDI"),
            ("myBCA", "", "BCA: 27/09 CR Rp10.000.000,00 TRANSFER DARI PT SUMBER REJEKI", 10_000_000, "PT SUMBER REJEKI"),
            ("Jenius", "", "You received IDR 500,000 from BUDI", 500_000, "BUDI"),
            ("BRImo", "", "Gaji Rp5.000.000 masuk ke rekening kamu", 5_000_000, "Gaji"),
            ("ShopeePay", "Refund Berhasil",
             "Refund Rp50.000 untuk pesanan yang dibatalkan telah masuk ke ShopeePay", 50_000, "Refund"),
        ]
        for c in cases {
            let r = try XCTUnwrap(read(c.body, title: c.title, app: c.app), c.body)
            XCTAssertEqual(r.amount, c.amount, c.body)
            XCTAssertEqual(r.name, c.name, c.body)
        }
        XCTAssertEqual(read("Gaji Rp5.000.000 masuk ke rekening kamu", app: "BRImo")?.category, .salary)
    }

    /// "Ke" names where money in arrived, which is the user's own account,
    /// not who sent it.
    func testMoneyInIsNotNamedAfterTheUsersOwnAccount() {
        let r = read("Dana masuk sebesar Rp1.000.000 ke rekening ****5678",
                     title: "Transaksi Berhasil", app: "Livin' by Mandiri")
        XCTAssertEqual(r?.amount, 1_000_000)
        XCTAssertEqual(r?.name, "Livin' by Mandiri")
        XCTAssertEqual(r?.accountTail, "5678")
    }

    /// A shop's QRIS takings are money in, though they say "pembayaran".
    func testAMerchantAppsPaymentsAreTakings() {
        let shown = read("Pembayaran QRIS Rp15.000 diterima", title: "Pembayaran Diterima", app: "GoPay Merchant")
        XCTAssertEqual(shown?.amount, 15_000)
        XCTAssertEqual(shown?.category, .business)
        XCTAssertEqual(read("Pembayaran QRIS Rp20.000 berhasil", app: "DANA Bisnis")?.amount, 20_000)
        XCTAssertEqual(read("Pembayaran Rp15.000 dari BUDI diterima", app: "GoPay Merchant")?.name, "BUDI")
        // The same words from a shopper's wallet are money out.
        XCTAssertEqual(read("Pembayaran QRIS Rp20.000 berhasil", app: "DANA")?.amount, -20_000)
    }

    /// A wallet's own top-up is money arriving in it; the bank's side of the
    /// same move, or a top-up that bought something, is money out.
    func testTopUps() {
        XCTAssertEqual(read("Top up Rp100.000 berhasil", title: "Top Up Berhasil", app: "GoPay")?.amount, 100_000)
        XCTAssertEqual(read("Isi saldo Rp50.000 berhasil", app: "ShopeePay")?.amount, 50_000)
        XCTAssertEqual(read("Saldo DANA kamu bertambah Rp100.000", title: "Top Up Berhasil", app: "DANA")?.amount,
                       100_000)
        XCTAssertEqual(read("Top up GoPay Rp100.000 berhasil", app: "BRImo")?.amount, -100_000)
        XCTAssertEqual(read("Top up OVO Rp50.000 berhasil", app: "DANA")?.amount, -50_000)
        XCTAssertEqual(read("Top up pulsa Rp50.000 berhasil", app: "DANA")?.amount, -50_000)
    }

    /// The words nearest the amount decide, and a word that says which way
    /// outranks one that only names the kind of payment.
    func testDirectionReadsTheSentenceWithTheAmount() {
        XCTAssertEqual(read("Pembayaran Rp45.000 di Indomaret berhasil. Kamu dapat cashback Rp4.500",
                            app: "GoPay")?.amount, -45_000)
        XCTAssertEqual(read("Rp45.000 berhasil dibayar di Indomaret. Poin masuk ke akunmu", app: "GoPay")?.amount,
                       -45_000)
        // "Kartu kredit" names a card, not money in.
        XCTAssertEqual(read("Transaksi Kartu Kredit BCA ****1234 Rp500.000 di TOKOPEDIA berhasil",
                            app: "myBCA")?.amount, -500_000)
        XCTAssertEqual(read("Pembayaran Angsuran Kredit Rp850.000 berhasil", app: "BRImo")?.amount, -850_000)
        // An employer paying wages is paying out.
        XCTAssertEqual(read("Pembayaran gaji karyawan Rp2.000.000 berhasil", app: "BRImo")?.amount, -2_000_000)
    }

    // MARK: Never kept

    /// A transfer's OTP carries an amount and a "transfer ke" and looks like
    /// the transfer itself. It must never reach the queue, words and all.
    func testCodesAreSecrets() {
        let codes: [(String, String)] = [
            ("myBCA", "BCA: Kode OTP Anda 449120. RAHASIA."),
            ("GoPay", "123456 adalah kode untuk masuk ke akun GoPay kamu. JANGAN BERIKAN kode ini ke siapa pun"),
            ("Livin' by Mandiri", "Kode OTP untuk transfer Rp500.000 ke BUDI adalah 482913. Jangan berikan ke siapapun."),
            ("DANA", "Gunakan kode 739201 untuk menyelesaikan transaksi Rp250.000 di Tokopedia."),
            ("Shopee", "<#> 4821 adalah kode verifikasi Shopee kamu"),
            ("Jenius", "Your code is 551234. Transfer of IDR 1,000,000 to BUDI"),
            ("BRImo", "Transfer Rp100.000 berhasil. Kode:839201"),
            ("BRImo", "Masukkan PIN untuk konfirmasi pembayaran Rp50.000"),
        ]
        for (app, body) in codes {
            XCTAssertEqual(verdict(body, app: app), .secret, body)
            XCTAssertNil(read(body, app: app), body)
        }
    }

    /// Whole words only: "otp" inside a restaurant's name is not a code, and a
    /// year, a reference or a PLN token is not one either.
    func testNumbersThatAreNotCodes() {
        XCTAssertEqual(verdict("Transaksi berhasil Rp50.000 di Hotpot Ya", app: "GoPay"), .payment)
        XCTAssertEqual(verdict("Kode booking ABC123: tiket Rp350.000 berhasil dibayar, 23 Okt 2026", app: "DANA"),
                       .payment)
        XCTAssertEqual(verdict("Pembelian Token PLN Rp100.000 berhasil. Token: 1234-5678-9012-3456-7890",
                               app: "DANA"), .payment)
    }

    func testNoMoneyMoved() {
        let notes: [(String, String)] = [
            ("Shopee", "Diskon s.d. Rp50.000 untuk belanja pertama! Klaim sekarang"),
            ("DANA", "Cashback hingga Rp20.000 pakai DANA. Berlaku s/d 31 Okt"),
            ("Shopee", "Gratis ongkir min. belanja Rp30.000"),
            ("Shopee", "Sepatu cuma Rp99.000! Buruan sebelum habis"),
            ("GoPay", "Voucher Rp10.000 untukmu, berlaku sampai Minggu"),
            ("Adira", "Kredit motor bunga 0% mulai Rp500.000/bulan"),
            ("Livin' by Mandiri", "Tagihan PLN kamu Rp150.000 sudah terbit. Bayar sebelum 20 Okt"),
            ("myBCA", "Tagihan kartu kredit Rp2.500.000 jatuh tempo 25/10"),
            ("myBCA", "E-Statement Oktober kamu sudah tersedia. Total tagihan Rp2.500.000"),
            ("GoPay", "Pembayaran Rp50.000 gagal. Saldo kamu tidak cukup"),
            ("BRImo", "Transfer Rp100.000 sedang diproses"),
            ("Shopee", "Selesaikan pembayaran Rp75.000 sebelum 23:59 dengan kode pembayaran 8808123456789012"),
            ("DANA", "BUDI meminta Rp50.000 untuk patungan makan"),
            ("DANA", "Transaksi gagal. Dana Rp50.000 akan dikembalikan dalam 1x24 jam"),
            ("BRImo", "Konfirmasi transaksi Rp500.000 di Tokopedia? Balas YA"),
            ("Shopee", "Pesanan #2310ABC senilai Rp150.000 sudah dikirim"),
            ("GoPay", "Saldo kamu saat ini Rp50.000"),
            ("Pluang", "Harga emas hari ini Rp1.200.000/gram"),
            ("Bibit", "Reksa dana kamu naik Rp5.000 hari ini"),
            ("Shopee", "Penjual: barangnya Rp50.000 ya kak, ready"),
            ("myBCA", "Login berhasil di perangkat baru pada 23/10/2026 10:00"),
        ]
        for (app, body) in notes {
            XCTAssertEqual(verdict(body, app: app), .notMoney, body)
            XCTAssertNil(read(body, app: app), body)
        }
    }

    /// DiPo's own reminders talk about money; if the user adds DiPo to the
    /// automation, they must not come back as payments.
    func testDiPosOwnNotificationsAreIgnored() {
        XCTAssertNil(read("Rp500.000 berhasil kamu bayar minggu ini", app: "DiPo"))
    }

    // MARK: Bank SMS

    /// A bank's SMS is terse and comes from a sender the user picked, so it
    /// needn't say that money moved. A code or a promo still never passes:
    /// the bank's number sends those too.
    func testBankMessagesAreScreenedToo() {
        let payments = [
            "BCA: 27/09 DB Rp50.000,00 QRIS WARKOP PAK BUDI",
            "Trx Rek. xxxx0969: Transfer IBNK ke BUDI SANTOSO Rp. 250000.00 27/09/26 21:22:13",
            "BCA: 27/09 CR Rp10.000.000,00 TRANSFER DARI PT SUMBER REJEKI",
            "BRI: Transaksi Rp50.000 di INDOMARET",
        ]
        for message in payments {
            XCTAssertEqual(NotificationTx.screen(message), .payment, message)
        }
        XCTAssertEqual(NotificationTx.screen("BCA: Kode OTP Anda 449120 untuk transfer Rp500.000. RAHASIA."), .secret)
        XCTAssertEqual(NotificationTx.screen("BRI: Nikmati cashback hingga Rp50.000 pakai BRImo"), .notMoney)
        XCTAssertEqual(NotificationTx.screen("Tagihan kartu kredit Rp2.500.000 jatuh tempo 25/10"), .notMoney)
        XCTAssertEqual(NotificationTx.screen("BCA: Login berhasil di perangkat baru"), .notMoney)
        // The same terse line from an app's notification has to say more.
        XCTAssertEqual(verdict("BRI: Transaksi Rp50.000 di INDOMARET", app: "BRImo"), .notMoney)
    }

    // MARK: The notice

    func testTheTitleIsReadOnceAndTheBannerIsKeptAsSeen() {
        let notice = NotificationTx.Notice(body: "Pembayaran Berhasil\nKamu bayar Rp25.000 ke Kopi Kenangan",
                                           title: "Pembayaran Berhasil", app: "GoPay")
        XCTAssertEqual(notice.text, "Pembayaran Berhasil\nKamu bayar Rp25.000 ke Kopi Kenangan")
        XCTAssertEqual(notice.shown, "GoPay\nPembayaran Berhasil\nKamu bayar Rp25.000 ke Kopi Kenangan")
    }

    /// Whatever arrives is capped before anything reads it or keeps it.
    func testALongNotificationIsCapped() {
        let notice = NotificationTx.Notice(body: String(repeating: "a", count: 5_000),
                                           title: String(repeating: "b", count: 500), app: "GoPay")
        XCTAssertEqual(notice.body.count, 1_000)
        XCTAssertEqual(notice.title.count, 200)
    }

    // MARK: Which bank or wallet

    func testTheAppNamesItsBankOrWallet() {
        let apps: [(String, String?)] = [
            ("Livin' by Mandiri", "mandiri"), ("BRImo", "bri"), ("myBCA", "bca"), ("BCA mobile", "bca"),
            ("blu by BCA Digital", "blu"), ("wondr by BNI", "bni"), ("BYOND by BSI", "bsi"),
            ("OCTO Mobile", "cimb"), ("Jago", "jago"), ("SeaBank", "seabank"), ("LINE Bank", "linebank"),
            ("GoPay", "gopay"), ("GoPay Merchant", "gopay"), ("DANA", "dana"), ("ShopeePay", "shopeepay"),
            ("OVO", "ovo"), ("Shopee", nil), ("Tokopedia", nil), ("", nil),
        ]
        for (app, issuer) in apps {
            XCTAssertEqual(NotificationTx.issuer(ofApp: app), issuer, app)
        }
    }

    // MARK: Which card

    private var container: ModelContainer!

    override func setUpWithError() throws {
        let schema = Schema(versionedSchema: DiPoSchemaCurrent.self)
        container = try ModelContainer(for: schema,
                                       configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    }

    override func tearDownWithError() throws {
        container = nil
    }

    private func card(_ holder: String, _ number: String, issuer: String = "") -> BankCard {
        let c = BankCard(holderName: holder, cardNumber: number, balance: 0, expireDate: "11/29",
                         gradientStart: "#000000", gradientEnd: "#111111", sortOrder: 0, currency: "IDR")
        c.issuerID = issuer
        container.mainContext.insert(c)
        return c
    }

    private func wallet(_ provider: String, holder: String = "Fahmi Aquinas") -> BankCard {
        let w = BankCard(holderName: holder, cardNumber: provider, balance: 0, expireDate: "Digital",
                         gradientStart: "#00AED6", gradientEnd: "#006E8A", sortOrder: 0, currency: "IDR",
                         isDigitalWallet: true, walletProvider: provider)
        container.mainContext.insert(w)
        return w
    }

    /// The bank picked for a card, the wallet picked for it, or the bank
    /// written at the end of its name. Everyday words don't count there.
    func testACardsBankOrWallet() {
        XCTAssertEqual(NotificationTx.issuer(of: card("Fahmi Aquinas BRI", "5221845086220969")), "bri")
        XCTAssertEqual(NotificationTx.issuer(of: card("Tabungan", "4111111111110001", issuer: "mandiri")), "mandiri")
        XCTAssertEqual(NotificationTx.issuer(of: wallet("GoPay")), "gopay")
        XCTAssertEqual(NotificationTx.issuer(of: wallet("blu by BCA")), "blu")
        XCTAssertEqual(NotificationTx.issuer(of: wallet("Other", holder: "ShopeePay")), "shopeepay")
        XCTAssertEqual(NotificationTx.issuer(of: card("Mega Wati BCA", "4111111111110002")), "bca")
        XCTAssertNil(NotificationTx.issuer(of: card("Dana Darurat", "4111111111110003")),
                     "Dana Darurat is an emergency fund, not the DANA wallet.")
        XCTAssertNil(NotificationTx.issuer(of: card("Brian Santoso", "4111111111110004")),
                     "Brian is not BRI.")
    }

    /// Fahmi's cards: BRI, BCA and Mandiri, with the bank written in the name,
    /// and a GoPay wallet.
    private func fahmisCards() -> (bri: BankCard, bca: BankCard, mandiri: BankCard, gopay: BankCard) {
        (card("Fahmi Aquinas BRI", "5221845086220969"), card("Fahmi Aquinas BCA", "4111111111119331"),
         card("Fahmi Aquinas Mandiri", "4111111111113661"), wallet("GoPay"))
    }

    func testTheSendingAppPicksTheCard() throws {
        let f = fahmisCards()
        let all = [f.bri, f.bca, f.mandiri, f.gopay]
        let livin = try XCTUnwrap(read("Transfer ke BUDI SANTOSO sebesar Rp250.000 berhasil.", app: "Livin' by Mandiri"))
        XCTAssertEqual(NotificationTx.card(for: livin, in: all)?.id, f.mandiri.id)
        let gopay = try XCTUnwrap(read("Kamu bayar Rp25.000 ke Kopi Kenangan pakai GoPay.", app: "GoPay"))
        XCTAssertEqual(NotificationTx.card(for: gopay, in: all)?.id, f.gopay.id)
    }

    /// "Transfer ke rek ****9331" in a Mandiri notification names where the
    /// money went. It left Mandiri.
    func testAnAccountTailFromAnotherBankDoesNotMoveThePayment() throws {
        let f = fahmisCards()
        let r = try XCTUnwrap(read("Transfer Rp500.000 ke rek ****9331 berhasil", app: "Livin' by Mandiri"))
        XCTAssertEqual(NotificationTx.card(for: r, in: [f.bri, f.bca, f.mandiri, f.gopay])?.id, f.mandiri.id)
    }

    /// Two cards of the app's bank: the tail picks one, and with no tail the
    /// queue asks rather than guesses.
    func testTwoCardsOfOneBank() throws {
        let one = card("Fahmi Aquinas BRI", "5221845086220969")
        let two = card("Simpanan BRI", "5221845086221234")
        let tailed = try XCTUnwrap(read("Transaksi Debit Rp50.000 dari rek ****1234 berhasil", app: "BRImo"))
        XCTAssertEqual(NotificationTx.card(for: tailed, in: [one, two])?.id, two.id)
        let bare = try XCTUnwrap(read("Tarik tunai Rp500.000 di ATM BRI berhasil", app: "BRImo"))
        XCTAssertNil(NotificationTx.card(for: bare, in: [one, two]))
    }

    /// A shop's app says nothing about the card; a wallet its message names does.
    func testAShopsNotificationUsesTheWalletItNames() throws {
        let f = fahmisCards()
        let spay = wallet("Other", holder: "ShopeePay")
        let named = try XCTUnwrap(read("Pembayaran ShopeePay Rp45.000 berhasil", app: "Shopee"))
        XCTAssertEqual(NotificationTx.card(for: named, in: [f.bri, f.gopay, spay])?.id, spay.id)
        let unnamed = try XCTUnwrap(read("Pembayaran Rp123.456 untuk pesanan 2310 berhasil.", app: "Shopee"))
        XCTAssertNil(NotificationTx.card(for: unnamed, in: [f.bri, f.gopay, spay]))
    }

    /// A payment from an app whose bank has no card in DiPo goes to no card,
    /// not to whichever card its words happen to mention.
    func testAnAppWithNoCardInDiPoPicksNone() throws {
        let f = fahmisCards()
        let r = try XCTUnwrap(read("Kamu bayar Rp20.000 ke Toko BRI Link pakai DANA", app: "DANA"))
        XCTAssertNil(NotificationTx.card(for: r, in: [f.bri, f.bca, f.mandiri, f.gopay]))
    }
}
