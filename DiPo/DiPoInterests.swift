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

    var id: String { rawValue }

    var emoji: String {
        switch self {
        case .coffee: return "☕"
        case .food:   return "🍜"
        case .travel: return "✈️"
        case .sport:  return "⚽"
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

    /// The line Ask DiPo sends with the financial context.
    static func contextLine(_ liked: Set<DiPoInterest>) -> String? {
        guard !liked.isEmpty else { return nil }
        let names = DiPoInterest.allCases.filter(liked.contains).map(\.contextName).joined(separator: ", ")
        return "Interests the user confirmed: \(names)."
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

/// From Profile: what DiPo thinks the user likes, to change freely.
struct DiPoInterestsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var liked = DiPoInterestStore.liked

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
                        VStack(spacing: 0) {
                            ForEach(DiPoInterest.allCases) { interest in
                                Toggle(isOn: Binding(
                                    get: { liked.contains(interest) },
                                    set: { on in
                                        HapticManager.shared.tap()
                                        DiPoInterestStore.set(interest, liked: on)
                                        liked = DiPoInterestStore.liked
                                    })) {
                                    HStack(spacing: 10) {
                                        Text(interest.emoji).font(.system(.title3))
                                        Text(interest.title)
                                            .font(.system(.subheadline, weight: .medium))
                                            .foregroundStyle(AppTheme.textPrimary)
                                    }
                                }
                                .tint(AppTheme.accent)
                                .frame(minHeight: 52)
                                if interest != DiPoInterest.allCases.last {
                                    Divider().overlay(AppTheme.cardMid)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
                    }
                    .padding(.horizontal, 20).padding(.top, 8)
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
}
