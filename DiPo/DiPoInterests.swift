import SwiftUI

// MARK: - What the user enjoys
//
// DiPo gets closer by knowing what the user likes: coffee, eating out,
// travelling, sport. He guesses from their own transactions — a run of
// coffee-shop purchases, flights and hotels, futsal court bookings — then
// asks before acting on the guess ("You like your coffee, don't you?").
// Only a "yes" makes it an interest; a "no" is remembered too, so he never
// asks twice. Confirmed interests ride along in Ask DiPo's context, where
// the assistant uses them for budget-minded recommendations, and each one
// gets a one-tap question in Ask DiPo.
//
// Royal only, like chatting with DiPo. Kept on this device in
// UserDefaults: it is a preference about DiPo's conversation, not part of
// the user's financial records, so it is not a @Model and not in backups.

enum DiPoInterest: String, CaseIterable, Identifiable {
    case coffee, food, travel, sport
    // Added 2026-10. The first four were what Fahmi happened to spend on;
    // these are what DiPo's users do — many of them outside the cities, so
    // farming, fishing and the motorbike are here beside games and gadgets.
    case game, music, movies, reading, fashion, selfcare, gadget, pets
    case farming, fishing, automotive, family, faith

    var id: String { rawValue }

    var emoji: String {
        switch self {
        case .coffee:     return "☕"
        case .food:       return "🍜"
        case .travel:     return "✈️"
        case .sport:      return "⚽"
        case .game:       return "🎮"
        case .music:      return "🎵"
        case .movies:     return "🎬"
        case .reading:    return "📚"
        case .fashion:    return "👗"
        case .selfcare:   return "💆"
        case .gadget:     return "📱"
        case .pets:       return "🐱"
        case .farming:    return "🌱"
        case .fishing:    return "🎣"
        case .automotive: return "🏍️"
        case .family:     return "👨‍👩‍👧"
        case .faith:      return "🙏"
        }
    }

    var title: String { loc("interest.\(rawValue)") }
    /// DiPo's guess, asked in his bubble: "You like your coffee, don't you?"
    var question: String { loc("interest.\(rawValue).ask") }
    /// The one-tap question in Ask DiPo once the interest is confirmed.
    var prompt: String { loc("interest.\(rawValue).prompt") }
    /// How the interest is named to the assistant, in English.
    var contextName: String {
        switch self {
        case .coffee: return "coffee and cafés"
        case .food:   return "food and trying new places to eat"
        case .travel: return "travelling"
        case .sport:  return "sport (futsal, badminton, gym, running)"
        case .game:       return "video and mobile games"
        case .music:      return "music and concerts"
        case .movies:     return "films, cinema and streaming"
        case .reading:    return "books, courses and learning"
        case .fashion:    return "fashion and clothes"
        case .selfcare:   return "self-care (skincare, haircuts, massage)"
        case .gadget:     return "phones and gadgets"
        case .pets:       return "their pets"
        case .farming:    return "gardening and farming"
        case .fishing:    return "fishing"
        case .automotive: return "their motorbike or car"
        case .family:     return "family and children"
        case .faith:      return "worship and giving (alms, zakat, qurban, pilgrimage, offerings)"
        }
    }

    /// Words in a transaction's name or note that point at the interest.
    /// Lower-case; matched as substrings.
    var keywords: [String] {
        switch self {
        case .coffee:
            return ["kopi", "coffee", "cafe", "café", "kafe", "starbucks", "latte", "espresso",
                    "americano", "cappuccino", "janji jiwa", "kenangan", "fore ", "tomoro",
                    "point coffee", "excelso", "kopken"]
        case .food:
            return ["gofood", "grabfood", "shopeefood", "resto", "restoran", "restaurant", "warung",
                    "bakso", "mie ", "ramen", "sushi", "martabak", "seblak", "dimsum", "pizza",
                    "burger", "kuliner", "makan malam", "dinner", "lunch", "brunch"]
        case .travel:
            return ["tiket pesawat", "pesawat", "flight", "hotel", "villa", "traveloka", "tiket.com",
                    "agoda", "airbnb", "kereta", "kai ", "whoosh", "garuda", "lion air", "citilink",
                    "airasia", "liburan", "wisata", "trip", "staycation"]
        case .sport:
            return ["futsal", "badminton", "bulu tangkis", "gym", "fitness", "lapangan", "sepatu lari",
                    "running", "lari", "renang", "kolam renang", "yoga", "padel", "tenis", "basket",
                    "sepak bola", "soccer", "jersey", "decathlon"]
        case .game:
            return ["diamond ml", "mobile legends", "mlbb", "free fire", "pubg",
                    "steam", "playstation", "psn", "nintendo", "xbox", "genshin", "voucher game",
                    "codashop", "unipin"]
        case .music:
            return ["spotify", "joox", "konser", "concert", "festival musik", "karaoke", "inul vizta",
                    "gitar", "apple music", "youtube music", "resonance"]
        case .movies:
            return ["bioskop", "xxi", "cgv", "cinepolis", "netflix", "disney+", "disney plus", "vidio",
                    "viu", "prime video", "nonton", "hbo go", "wetv"]
        case .reading:
            return ["buku", "gramedia", "periplus", "kursus", "course", "udemy", "coursera", "kelas online",
                    "kindle", "ebook", "seminar", "workshop", "les privat"]
        case .fashion:
            return ["baju", "kaos", "celana", "kemeja", "uniqlo", "h&m", "zara", "jaket", "hijab",
                    "gamis", "batik", "fashion", "erigo"]
        case .selfcare:
            return ["skincare", "salon", "barbershop", "barber", "potong rambut", "cukur", "spa", "pijat",
                    "massage", "facial", "sociolla", "guardian", "watsons", "creambath"]
        case .gadget:
            return ["iphone", "samsung", "xiaomi", "oppo", "vivo", "realme", "laptop", "charger",
                    "earphone", "headset", "airpods", "ibox", "erafone", "casing hp", "tablet", "ipad",
                    "smartwatch"]
        case .pets:
            return ["kucing", "anjing", "whiskas", "royal canin", "pet shop", "petshop", "dokter hewan",
                    "pasir kucing", "makanan kucing", "me-o", "grooming", "pakan burung"]
        case .farming:
            return ["pupuk", "bibit", "benih", "pestisida", "tanaman", "kebun", "sawah", "traktor",
                    "cangkul", "polybag", "urea", "npk", "pakan ternak", "ternak", "panen"]
        case .fishing:
            return ["pancing", "mancing", "umpan", "joran", "reel", "pemancingan", "senar"]
        case .automotive:
            return ["bengkel", "ganti oli", "oli mesin", "servis motor", "service motor", "servis mobil",
                    "ganti ban", "sparepart", "suku cadang", "cuci motor", "cuci mobil", "helm", "ahass"]
        case .family:
            return ["susu anak", "popok", "pampers", "mamypoko", "sweety", "mainan", "sekolah", "spp",
                    "uang saku", "seragam", "bayi", "baby"]
        case .faith:
            return ["zakat", "infaq", "infak", "sedekah", "kurban", "qurban", "umroh", "umrah", "haji",
                    "masjid", "pengajian", "kitabisa", "persembahan", "kolekte", "perpuluhan", "donasi"]
        }
    }

    /// Hits within this many days count towards a guess.
    static let lookbackDays = 60
    /// This many matching transactions make a guess worth asking about.
    static let threshold = 3

    /// How many recent transactions point at each interest.
    static func counts(in transactions: [TxRecord], now: Date = .now) -> [DiPoInterest: Int] {
        let floor = now.addingTimeInterval(-Double(lookbackDays) * 86_400)
        var out: [DiPoInterest: Int] = [:]
        for tx in transactions where tx.date >= floor && tx.amount < 0 {
            let text = (tx.name + " " + tx.notes).lowercased() + " "
            for interest in allCases {
                // A flight booked under the Travel category counts even when
                // its name says nothing.
                let byCategory = interest == .travel && tx.category == .travel
                if byCategory || interest.keywords.contains(where: { text.contains($0) }) {
                    out[interest, default: 0] += 1
                }
            }
        }
        return out
    }

    /// The interest DiPo should ask about next: seen often enough, and not
    /// yet answered either way. The strongest signal goes first.
    static func nextGuess(in transactions: [TxRecord], answered: Set<DiPoInterest>,
                          now: Date = .now) -> DiPoInterest? {
        counts(in: transactions, now: now)
            .filter { $0.value >= threshold && !answered.contains($0.key) }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.rawValue < $1.key.rawValue }
            .first?.key
    }
}

/// The user's answers, on this device.
enum DiPoInterestStore {
    private static let yesKey = "dipo_interests_yes"
    private static let noKey = "dipo_interests_no"

    static var liked: Set<DiPoInterest> { read(yesKey) }
    static var declined: Set<DiPoInterest> { read(noKey) }
    static var answered: Set<DiPoInterest> { liked.union(declined) }

    static func set(_ interest: DiPoInterest, liked isLiked: Bool) {
        var yes = liked, no = declined
        if isLiked { yes.insert(interest); no.remove(interest) } else { no.insert(interest); yes.remove(interest) }
        write(yes, yesKey)
        write(no, noKey)
    }

    // MARK: In the user's own words
    //
    // A list cannot hold everything people enjoy — songbirds, batik, kopi
    // tubruk. These are typed by the user, kept as typed, and never guessed:
    // there are no keywords to look for. They ride in Ask DiPo's context and
    // take their turn in DiPo's ideas like the rest.

    private static let customKey = "dipo_interests_custom"
    static let customLimit = 5
    static let customMaxLength = 30

    /// Stored as one line each in a single string, so a view can observe it
    /// through @AppStorage like the other answers.
    static var custom: [String] {
        (UserDefaults.standard.string(forKey: customKey) ?? "")
            .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    private static func writeCustom(_ list: [String]) {
        UserDefaults.standard.set(list.joined(separator: "\n"), forKey: customKey)
    }

    /// Adds one, trimmed; ignores an empty or repeated one or one past the limit.
    /// Returns whether it was added.
    @discardableResult
    static func addCustom(_ raw: String) -> Bool {
        let name = String(raw.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines).prefix(customMaxLength))
        var list = custom
        guard !name.isEmpty, list.count < customLimit,
              !list.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { return false }
        list.append(name)
        writeCustom(list)
        return true
    }

    static func removeCustom(_ name: String) {
        writeCustom(custom.filter { $0 != name })
    }

    /// The line Ask DiPo sends with the financial context.
    static func contextLine(_ liked: Set<DiPoInterest>, custom: [String] = []) -> String? {
        var parts: [String] = []
        if !liked.isEmpty {
            parts.append(DiPoInterest.allCases.filter(liked.contains).map(\.contextName).joined(separator: ", "))
        }
        if !custom.isEmpty {
            parts.append("in their own words: " + custom.map { "\"\($0)\"" }.joined(separator: ", "))
        }
        guard !parts.isEmpty else { return nil }
        return "Interests the user confirmed: \(parts.joined(separator: "; "))."
    }

    private static func read(_ key: String) -> Set<DiPoInterest> {
        let raw = UserDefaults.standard.string(forKey: key) ?? ""
        return Set(raw.split(separator: ",").compactMap { DiPoInterest(rawValue: String($0)) })
    }

    private static func write(_ set: Set<DiPoInterest>, _ key: String) {
        UserDefaults.standard.set(set.map(\.rawValue).sorted().joined(separator: ","), forKey: key)
    }
}

// MARK: - Managing them

/// From Profile: what DiPo thinks the user likes, to change freely — tap a
/// chip to turn it on or off, or write your own.
struct DiPoInterestsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var liked = DiPoInterestStore.liked
    @State private var custom = DiPoInterestStore.custom
    @State private var draft = ""

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(loc("interest.profile_intro"))
                            .font(.system(.footnote))
                            .foregroundStyle(AppTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                        InterestFlow(spacing: 8) {
                            ForEach(DiPoInterest.allCases) { interest in
                                let on = liked.contains(interest)
                                Button {
                                    HapticManager.shared.tap()
                                    DiPoInterestStore.set(interest, liked: !on)
                                    liked = DiPoInterestStore.liked
                                } label: {
                                    chip("\(interest.emoji) \(interest.title)", on: on)
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(on ? .isSelected : [])
                            }
                        }

                        Text(loc("interest.custom_title"))
                            .font(.system(.caption, weight: .bold))
                            .foregroundStyle(AppTheme.textSecondary)
                            .textCase(.uppercase)
                            .padding(.top, 6)

                        if !custom.isEmpty {
                            InterestFlow(spacing: 8) {
                                ForEach(custom, id: \.self) { name in
                                    Button {
                                        HapticManager.shared.tap()
                                        DiPoInterestStore.removeCustom(name)
                                        custom = DiPoInterestStore.custom
                                    } label: {
                                        HStack(spacing: 6) {
                                            Text("✨ \(name)")
                                            Image(systemName: "xmark").font(.system(.caption2, weight: .bold))
                                                .foregroundStyle(AppTheme.textSecondary)
                                        }
                                        .modifier(ChipStyle(on: true))
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(String(format: loc("interest.custom_remove"), name))
                                }
                            }
                        }

                        if custom.count < DiPoInterestStore.customLimit {
                            HStack(spacing: 8) {
                                TextField(loc("interest.custom_placeholder"), text: $draft)
                                    .font(.system(.subheadline))
                                    .submitLabel(.done)
                                    .onSubmit(addDraft)
                                    .padding(.horizontal, 14).padding(.vertical, 12)
                                    .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
                                Button(action: addDraft) {
                                    Text(loc("interest.custom_add"))
                                        .font(.system(.subheadline, weight: .bold))
                                        .foregroundStyle(AppTheme.onVividFill)
                                        .padding(.horizontal, 16).padding(.vertical, 12)
                                        .background(AppTheme.accentFill, in: RoundedRectangle(cornerRadius: AppRadius.md))
                                }
                                .buttonStyle(ScaleButtonStyle())
                                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                        }
                        Text(String(format: loc("interest.custom_limit"), DiPoInterestStore.customLimit))
                            .font(.system(.caption2))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                    .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 30)
                    .containerRelativeFrame(.horizontal)
                }
            }
            .navigationTitle(loc("interest.profile_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(loc("interest.done")) { dismiss() }.fontWeight(.semibold)
                }
            }
        }
    }

    private func chip(_ text: String, on: Bool) -> some View {
        Text(text).modifier(ChipStyle(on: on))
    }

    private func addDraft() {
        guard DiPoInterestStore.addCustom(draft) else { return }
        HapticManager.shared.success()
        draft = ""
        custom = DiPoInterestStore.custom
    }
}

/// A chip: filled with the accent when on, outlined when off.
private struct ChipStyle: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        content
            .font(.system(.subheadline, weight: .semibold))
            .foregroundStyle(on ? AppTheme.accent : AppTheme.textPrimary)
            .lineLimit(1)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(on ? AppTheme.accent.opacity(0.14) : AppTheme.cardDark, in: Capsule())
            .overlay(Capsule().stroke(on ? AppTheme.accent : AppTheme.cardMid, lineWidth: 1.5))
    }
}

/// Lays chips out in rows, wrapping to the next row when one is full.
private struct InterestFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
