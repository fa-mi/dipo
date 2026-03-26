import SwiftUI

// MARK: - Language Manager
// Custom localization system — no .lproj files needed.
// All translations live in this file for easy maintenance.
// Use loc("key") anywhere, or Text(loc("key")) in SwiftUI.

@Observable
final class LanguageManager {

    static let shared = LanguageManager()

    enum Language: String, CaseIterable, Identifiable {
        case english    = "en"
        case indonesian = "id"

        var id: String { rawValue }

        var flag: String {
            switch self {
            case .english:    return "🇬🇧"
            case .indonesian: return "🇮🇩"
            }
        }

        var nativeName: String {
            switch self {
            case .english:    return "English"
            case .indonesian: return "Bahasa Indonesia"
            }
        }
    }

    var current: Language {
        didSet {
            UserDefaults.standard.set(current.rawValue, forKey: "dipo_language")
            // Bump trigger so RootView .id() forces a full re-render
            renderID = UUID()
        }
    }

    /// Changes whenever language switches — attach to RootView's .id() to force refresh.
    private(set) var renderID = UUID()

    private init() {
        let saved = UserDefaults.standard.string(forKey: "dipo_language") ?? "en"
        self.current = Language(rawValue: saved) ?? .english
    }

    // MARK: - Translation

    func t(_ key: String) -> String {
        let table = current == .indonesian ? translationsID : translationsEN
        return table[key] ?? key   // falls back to the key itself if not translated yet
    }

    // MARK: - English Strings

    private let translationsEN: [String: String] = [
        // Tabs
        "tab.home":    "Home",
        "tab.stats":   "Stats",
        "tab.cards":   "Cards",
        "tab.profile": "Profile",

        // Common actions
        "action.add":     "Add",
        "action.save":    "Save",
        "action.cancel":  "Cancel",
        "action.delete":  "Delete",
        "action.edit":    "Edit",
        "action.done":    "Done",
        "action.confirm": "Confirm",
        "action.retry":   "Retry",
        "action.search":  "Search",
        "action.close":   "Close",
        "action.back":    "Back",
        "action.next":    "Next",
        "action.submit":  "Submit",
        "action.update":  "Update",

        // Home
        "home.greeting":      "Hello,",
        "home.transactions":  "Transactions",
        "home.see_more":      "See more",
        "home.view_all":      "View all",
        "home.income":        "Income",
        "home.expense":       "Expense",
        "home.balance":       "Balance",
        "home.today":         "Today",
        "home.yesterday":     "Yesterday",
        "home.setup_salary":  "Set up your salary",
        "home.setup_salary_sub": "Track your income and get payday reminders",
        "home.set_up":        "Set up",

        // Cards
        "cards.title":         "My Cards",
        "cards.total_balance": "Total balance",
        "cards.add_card":      "Add Card",
        "cards.new_card":      "New Card",
        "cards.card_number":   "Card Number",
        "cards.card_holder":   "Card Holder",
        "cards.expiry":        "Expiry Date",
        "cards.expires":       "Expires",
        "cards.transaction":   "transaction",
        "cards.transactions":  "transactions",
        "cards.expired":       "Expired",
        "cards.expires_soon":  "Expires soon",
        "cards.expires_week":  "Expires this week",
        "cards.digital_wallet":"Digital Wallet",

        // Transactions
        "tx.add":       "Add Transaction",
        "tx.category":  "Category",
        "tx.amount":    "Amount",
        "tx.date":      "Date",
        "tx.notes":     "Notes",
        "tx.income":    "Income",
        "tx.expense":   "Expense",

        // Profile
        "profile.title":      "Profile",
        "profile.settings":   "Settings",
        "profile.language":   "Language",
        "profile.appearance": "Appearance",
        "profile.salary":     "Salary Schedule",
        "profile.salary_sub": "Manage your income & payday",
        "profile.savings":    "Savings Goals",
        "profile.savings_sub":"Save for what matters most",
        "profile.budget":     "Smart Budget",
        "profile.debt":       "Smart Debt Tracker",
        "profile.debt_sub":   "Track & payoff debts faster",
        "profile.logout":     "Log Out",
        "profile.login":      "Log In",
        "profile.change_pin": "Change PIN",
        "profile.support":    "Contact Support",
        "profile.delete":     "Delete Account",
        "profile.premium":    "DiPo Royal",
        "profile.all_features":"All features unlocked",
        "profile.upgrade":    "Upgrade",

        // Appearance
        "appearance.light":   "Light",
        "appearance.dark":    "Dark",
        "appearance.system":  "System",
        "appearance.following_system": "Following system",
        "appearance.dark_mode": "Dark mode",
        "appearance.light_mode":"Light mode",

        // Support
        "support.title":         "Support",
        "support.new":           "New",
        "support.new_ticket":    "New Ticket",
        "support.no_tickets":    "No tickets yet",
        "support.no_tickets_sub":"Tap New to submit your first ticket.",
        "support.help":          "We're here to help",
        "support.response_time": "Usually respond within 24 hours",
        "support.subject":       "Subject",
        "support.message":       "Message",
        "support.send":          "Send Message",
        "support.bug":           "Bug Report",
        "support.feature":       "Feature Request",
        "support.billing":       "Billing",
        "support.other":         "Other",
        "support.attach":        "Attach Screenshots",
        "support.attach_sub":    "Helps us reproduce the issue faster",
        "support.add_photo":     "Add photo",
        "support.submitted":     "Ticket submitted!",
        "support.submitted_sub": "We'll reply within 24 hours.",
        "support.write_reply":   "Write a reply…",
        "support.answered":      "Answered",
        "support.open":          "Open",
        "support.closed":        "Closed",
        "support.submitted_step":"Submitted",
        "support.in_review":     "In Review",

        // Salary
        "salary.title":       "Salary Schedule",
        "salary.new":         "New Salary",
        "salary.label":       "Salary label",
        "salary.amount":      "Amount & Currency",
        "salary.payday":      "Intended payday",
        "salary.add":         "Add Salary Schedule",
        "salary.auto_credit": "Auto-credit starts next month",
        "salary.day_of":      "Day %d of every month",
        "salary.actual":      "This month's actual payday",
        "salary.moved":       "Moved earlier — day %d is a weekend or Indonesian public holiday",
        "salary.payday_reminder": "Payday reminder",
        "salary.days_left":   "%d days until payday",
        "salary.tomorrow":    "Payday tomorrow!",
        "salary.today":       "Payday today! 🎉",

        // Savings
        "savings.title":      "Savings Goals",

        // Smart Budget
        "budget.title":       "Smart Budget",
        "budget.off":         "Off — tap to configure",

        // Debt
        "debt.title":         "Smart Debt Tracker",

        // Network
        "network.no_connection":   "No Internet Connection",
        "network.check":           "Check connection",
        "network.checking":        "Checking connection…",
        "network.back_online":     "Back online — syncing…",
        "network.message":         "Please check your connection.\nSome features require internet to work.",
        "network.data_safe":       "Your existing data is safe and you can see it when online.",

        // Notifications
        "notif.card_expired":      "Card has expired",
        "notif.card_expires_soon": "Card expires soon",
        "notif.salary_incoming":   "Salary incoming in 3 days!",
        "notif.payday_tomorrow":   "Payday is tomorrow!",
    ]

    // MARK: - Indonesian Strings

    private let translationsID: [String: String] = [
        // Tabs
        "tab.home":    "Beranda",
        "tab.stats":   "Statistik",
        "tab.cards":   "Kartu",
        "tab.profile": "Profil",

        // Common actions
        "action.add":     "Tambah",
        "action.save":    "Simpan",
        "action.cancel":  "Batal",
        "action.delete":  "Hapus",
        "action.edit":    "Ubah",
        "action.done":    "Selesai",
        "action.confirm": "Konfirmasi",
        "action.retry":   "Coba Lagi",
        "action.search":  "Cari",
        "action.close":   "Tutup",
        "action.back":    "Kembali",
        "action.next":    "Lanjut",
        "action.submit":  "Kirim",
        "action.update":  "Perbarui",

        // Home
        "home.greeting":      "Halo,",
        "home.transactions":  "Transaksi",
        "home.see_more":      "Lihat lainnya",
        "home.view_all":      "Lihat semua",
        "home.income":        "Pemasukan",
        "home.expense":       "Pengeluaran",
        "home.balance":       "Saldo",
        "home.today":         "Hari ini",
        "home.yesterday":     "Kemarin",
        "home.setup_salary":  "Atur jadwal gaji",
        "home.setup_salary_sub": "Lacak pemasukan & dapatkan pengingat gajian",
        "home.set_up":        "Atur",

        // Cards
        "cards.title":         "Kartu Saya",
        "cards.total_balance": "Total saldo",
        "cards.add_card":      "Tambah Kartu",
        "cards.new_card":      "Kartu Baru",
        "cards.card_number":   "Nomor Kartu",
        "cards.card_holder":   "Nama Pemegang",
        "cards.expiry":        "Tanggal Kadaluarsa",
        "cards.expires":       "Kadaluarsa",
        "cards.transaction":   "transaksi",
        "cards.transactions":  "transaksi",
        "cards.expired":       "Sudah Kadaluarsa",
        "cards.expires_soon":  "Segera Kadaluarsa",
        "cards.expires_week":  "Kadaluarsa Minggu Ini",
        "cards.digital_wallet":"Dompet Digital",

        // Transactions
        "tx.add":       "Tambah Transaksi",
        "tx.category":  "Kategori",
        "tx.amount":    "Jumlah",
        "tx.date":      "Tanggal",
        "tx.notes":     "Catatan",
        "tx.income":    "Pemasukan",
        "tx.expense":   "Pengeluaran",

        // Profile
        "profile.title":      "Profil",
        "profile.settings":   "Pengaturan",
        "profile.language":   "Bahasa",
        "profile.appearance": "Tampilan",
        "profile.salary":     "Jadwal Gaji",
        "profile.salary_sub": "Kelola pemasukan & hari gajian",
        "profile.savings":    "Tujuan Tabungan",
        "profile.savings_sub":"Hemat untuk hal yang penting",
        "profile.budget":     "Anggaran Cerdas",
        "profile.debt":       "Pelacak Utang Cerdas",
        "profile.debt_sub":   "Lacak & lunasi utang lebih cepat",
        "profile.logout":     "Keluar",
        "profile.login":      "Masuk",
        "profile.change_pin": "Ganti PIN",
        "profile.support":    "Hubungi Dukungan",
        "profile.delete":     "Hapus Akun",
        "profile.premium":    "DiPo Royal",
        "profile.all_features":"Semua fitur terbuka",
        "profile.upgrade":    "Upgrade",

        // Appearance
        "appearance.light":   "Terang",
        "appearance.dark":    "Gelap",
        "appearance.system":  "Sistem",
        "appearance.following_system": "Mengikuti sistem",
        "appearance.dark_mode": "Mode gelap",
        "appearance.light_mode":"Mode terang",

        // Support
        "support.title":         "Dukungan",
        "support.new":           "Baru",
        "support.new_ticket":    "Tiket Baru",
        "support.no_tickets":    "Belum ada tiket",
        "support.no_tickets_sub":"Ketuk Baru untuk membuat tiket pertama.",
        "support.help":          "Kami siap membantu",
        "support.response_time": "Biasanya merespons dalam 24 jam",
        "support.subject":       "Subjek",
        "support.message":       "Pesan",
        "support.send":          "Kirim Pesan",
        "support.bug":           "Laporan Bug",
        "support.feature":       "Permintaan Fitur",
        "support.billing":       "Pembayaran",
        "support.other":         "Lainnya",
        "support.attach":        "Lampirkan Screenshot",
        "support.attach_sub":    "Membantu kami mereproduksi masalah lebih cepat",
        "support.add_photo":     "Tambah foto",
        "support.submitted":     "Tiket terkirim!",
        "support.submitted_sub": "Kami akan membalas dalam 24 jam.",
        "support.write_reply":   "Tulis balasan…",
        "support.answered":      "Terjawab",
        "support.open":          "Terbuka",
        "support.closed":        "Ditutup",
        "support.submitted_step":"Terkirim",
        "support.in_review":     "Sedang Ditinjau",

        // Salary
        "salary.title":       "Jadwal Gaji",
        "salary.new":         "Gaji Baru",
        "salary.label":       "Nama gaji",
        "salary.amount":      "Jumlah & Mata Uang",
        "salary.payday":      "Tanggal gajian",
        "salary.add":         "Tambah Jadwal Gaji",
        "salary.auto_credit": "Kredit otomatis mulai bulan depan",
        "salary.day_of":      "Tanggal %d setiap bulan",
        "salary.actual":      "Tanggal gajian bulan ini",
        "salary.moved":       "Dimajukan — tanggal %d adalah akhir pekan atau hari libur nasional",
        "salary.payday_reminder": "Pengingat gajian",
        "salary.days_left":   "%d hari lagi gajian",
        "salary.tomorrow":    "Gajian besok!",
        "salary.today":       "Gajian hari ini! 🎉",

        // Savings
        "savings.title":      "Tujuan Tabungan",

        // Smart Budget
        "budget.title":       "Anggaran Cerdas",
        "budget.off":         "Nonaktif — ketuk untuk mengatur",

        // Debt
        "debt.title":         "Pelacak Utang Cerdas",

        // Network
        "network.no_connection":   "Tidak Ada Koneksi Internet",
        "network.check":           "Periksa koneksi",
        "network.checking":        "Memeriksa koneksi…",
        "network.back_online":     "Kembali online — menyinkronkan…",
        "network.message":         "Periksa koneksi Anda.\nBeberapa fitur memerlukan internet.",
        "network.data_safe":       "Data Anda aman dan dapat dilihat saat online.",

        // Notifications
        "notif.card_expired":      "Kartu sudah kadaluarsa",
        "notif.card_expires_soon": "Kartu segera kadaluarsa",
        "notif.salary_incoming":   "Gaji masuk dalam 3 hari!",
        "notif.payday_tomorrow":   "Gajian besok!",
    ]
}

// MARK: - Global shorthand
// Use loc("key") anywhere in the app instead of LanguageManager.shared.t("key")

func loc(_ key: String) -> String {
    LanguageManager.shared.t(key)
}
