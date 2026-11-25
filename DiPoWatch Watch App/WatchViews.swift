import SwiftUI

// MARK: - DiPo on the wrist
//
// Two questions only: "how much is left?" and "log what I just spent".
// Cash spent at a warung goes in with three taps: the amount, what it was
// for, done. The iPhone saves it to the main card.
//
// Colours are DiPo's (AppTheme, dark): ink for figures, green for the one
// thing to press, blue for money put away, orange past income, the
// category's own hue on its circle.

enum WatchTheme {
    static let accent = Color(red: 0x1D / 255, green: 0xB8 / 255, blue: 0x7A / 255)
    static let onAccent = Color(red: 0x0D / 255, green: 0x15 / 255, blue: 0x14 / 255)
    static let secondary = Color(red: 0x8A / 255, green: 0x96 / 255, blue: 0x93 / 255)
    static let blue = Color(red: 0x38 / 255, green: 0xBD / 255, blue: 0xF8 / 255)
    static let orange = Color(red: 0xFB / 255, green: 0x92 / 255, blue: 0x3C / 255)
    static let key = Color(red: 0x2A / 255, green: 0x33 / 255, blue: 0x30 / 255)
    static let tile = Color(red: 0x22 / 255, green: 0x28 / 255, blue: 0x27 / 255)

    static func hex(_ string: String) -> Color {
        let v = UInt32(string.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x5B6F6B
        return Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
                     blue: Double(v & 0xFF) / 255)
    }
}

struct WatchRootView: View {
    @State private var store = WatchStore.shared
    @State private var path: [Step] = []

    enum Step: Hashable {
        case amount
        case category(Double)
        case saved(Double, WatchSnapshot.Category)
    }

    var body: some View {
        NavigationStack(path: $path) {
            GlanceView(store: store) { path.append(.amount) }
                .navigationDestination(for: Step.self) { step in
                    switch step {
                    case .amount:
                        AmountPadView(currency: store.snapshot?.currency ?? "IDR") { path.append(.category($0)) }
                    case .category(let amount):
                        CategoryPickView(store: store, amount: amount) { picked in
                            store.log(amount: amount, category: picked.raw)
                            path.append(.saved(amount, picked))
                        }
                    case .saved(let amount, let category):
                        SavedView(store: store, amount: amount, category: category) { path.removeAll() }
                    }
                }
        }
    }
}

// MARK: Glance

struct GlanceView: View {
    let store: WatchStore
    let onLog: () -> Void

    var body: some View {
        if let s = store.snapshot {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text(s.labels.title)
                        .font(.footnote)
                        .foregroundStyle(WatchTheme.secondary)
                    Text(s.hidden ? "••••••" : s.amount)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(s.over ? WatchTheme.orange : .white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    PeriodLine(living: s.living, putAway: s.putAway, over: s.over)
                        .padding(.vertical, 2)
                    if let payday = s.payday {
                        Text(payday).font(.footnote).foregroundStyle(WatchTheme.secondary)
                    }
                    if let perDay = s.perDay, !s.hidden {
                        Text(perDay).font(.footnote).foregroundStyle(WatchTheme.secondary)
                    }
                    if s.cardName == nil {
                        Text(s.labels.noCard)
                            .font(.footnote)
                            .foregroundStyle(WatchTheme.secondary)
                            .padding(.top, 6)
                    } else {
                        Button(action: onLog) {
                            Label(s.labels.log, systemImage: "plus")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(WatchTheme.accent)
                        .foregroundStyle(WatchTheme.onAccent)
                        .padding(.top, 8)
                    }
                    if store.pending > 0 {
                        Text("\(s.labels.pending) · \(store.pending)")
                            .font(.caption2)
                            .foregroundStyle(WatchTheme.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "iphone")
                    .font(.title2)
                    .foregroundStyle(WatchTheme.secondary)
                Text(WatchCopy.openPhone)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

/// Home's period line: living costs in ink (orange past income), money put
/// away in blue, the rest empty.
struct PeriodLine: View {
    let living: Double
    let putAway: Double
    let over: Bool

    var body: some View {
        GeometryReader { g in
            let l = min(max(living, 0), 1)
            let p = min(max(putAway, 0), 1 - l)
            ZStack(alignment: .leading) {
                Capsule().fill(WatchTheme.secondary.opacity(0.25))
                HStack(spacing: 0) {
                    Rectangle().fill(over ? WatchTheme.orange : .white).frame(width: g.size.width * l)
                    Rectangle().fill(WatchTheme.blue).frame(width: g.size.width * p)
                }
                .frame(width: g.size.width, alignment: .leading)
                .clipShape(Capsule())
            }
        }
        .frame(height: 6)
    }
}

// MARK: Tap 1: the amount

struct AmountPadView: View {
    let currency: String
    let onNext: (Double) -> Void

    @State private var digits = ""
    /// Turned by the Digital Crown, a thousand at a time.
    @State private var crown = 0.0

    private var amount: Double { Double(digits) ?? 0 }
    private let keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "000", "0", "⌫"]

    var body: some View {
        VStack(spacing: 4) {
            Text(WatchMoney.text(amount, currency: currency))
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .focusable()
                .digitalCrownRotation($crown, from: 0, through: 999_999_999_999, by: 1_000,
                                      sensitivity: .medium, isContinuous: false, isHapticFeedbackEnabled: true)
                .onChange(of: crown) { _, value in digits = value > 0 ? String(Int(value)) : "" }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 4) {
                ForEach(keys, id: \.self) { key in
                    Button { press(key) } label: {
                        Text(key == "⌫" ? "" : key)
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .frame(maxWidth: .infinity, minHeight: 28)
                            .overlay { if key == "⌫" { Image(systemName: "delete.left") } }
                    }
                    .buttonStyle(.plain)
                    .background(WatchTheme.key, in: RoundedRectangle(cornerRadius: 9))
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button { onNext(amount) } label: { Image(systemName: "checkmark") }
                    .disabled(amount <= 0)
            }
        }
    }

    private func press(_ key: String) {
        switch key {
        case "⌫": digits = String(digits.dropLast())
        case "000", "0": if !digits.isEmpty { digits = String((digits + key).prefix(12)) }
        default: digits = String((digits + key).prefix(12))
        }
        crown = amount
    }
}

// MARK: Tap 2: what it was for

struct CategoryPickView: View {
    let store: WatchStore
    let amount: Double
    let onPick: (WatchSnapshot.Category) -> Void

    var body: some View {
        let s = store.snapshot
        ScrollView {
            VStack(spacing: 8) {
                Text(String(format: s?.labels.forWhat ?? "%@",
                            WatchMoney.text(amount, currency: s?.currency ?? "IDR")))
                    .font(.footnote)
                    .foregroundStyle(WatchTheme.secondary)
                    .multilineTextAlignment(.center)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(s?.categories ?? [], id: \.self) { c in
                        Button { onPick(c) } label: {
                            VStack(spacing: 6) {
                                Image(systemName: c.symbol)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 32, height: 32)
                                    .background(WatchTheme.hex(c.hex), in: Circle())
                                Text(c.label)
                                    .font(.footnote)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                        .background(WatchTheme.tile, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
            }
        }
    }
}

// MARK: Done

struct SavedView: View {
    let store: WatchStore
    let amount: Double
    let category: WatchSnapshot.Category
    let onDone: () -> Void

    var body: some View {
        let s = store.snapshot
        ScrollView {
            VStack(spacing: 8) {
                Image(systemName: category.symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(WatchTheme.hex(category.hex), in: Circle())
                Text(s?.labels.saved ?? "")
                    .font(.headline)
                Text("\(category.label) · \(WatchMoney.text(amount, currency: s?.currency ?? "IDR"))")
                    .font(.footnote)
                    .foregroundStyle(WatchTheme.secondary)
                if let card = s?.cardName {
                    Text(String(format: s?.labels.savedTo ?? "%@", card))
                        .font(.footnote)
                        .foregroundStyle(WatchTheme.secondary)
                        .multilineTextAlignment(.center)
                }
                if store.pending > 0, let pending = s?.labels.pending {
                    Text(pending)
                        .font(.caption2)
                        .foregroundStyle(WatchTheme.secondary)
                }
                Button(WatchCopy.done, action: onDone)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
        }
        .navigationBarBackButtonHidden()
    }
}
