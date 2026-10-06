import SwiftUI

// MARK: - "Emas apa yang kamu punya?"
//
// Chosen from a short list rather than typed: a typed name has no price to
// look up. The list is the gold people in the segment actually hold — the
// Pegadaian savings balance (Tring/BRImo), the four bar brands sold through
// Pegadaian, and jewellery by purity. Anything else is "Other": it keeps the
// name the user gives it and follows a price they pick.

struct GoldSourcePicker: View {
    @Binding var source: GoldSource
    /// "Other" follows the same feeds as a listed choice; this remembers that
    /// the user picked it, so its follow-which-price row stays open.
    @Binding var isOther: Bool
    var idle: Color = AppTheme.bg

    private enum Choice: Hashable { case savings, bar(GoldBrand), jewelry, other }

    private var choice: Choice {
        if isOther { return .other }
        switch source {
        case .savings, .manual: return .savings
        case .bar(let b):       return .bar(b)
        case .jewelry:          return .jewelry
        }
    }

    private var choices: [Choice] {
        [.savings] + GoldBrand.allCases.map { .bar($0) } + [.jewelry, .other]
    }

    private func title(_ c: Choice) -> String {
        switch c {
        case .savings:    return loc("gold.src.savings_short")
        case .bar(let b): return b.displayName
        case .jewelry:    return loc("gold.src.jewelry")
        case .other:      return loc("gold.src.other")
        }
    }

    private func select(_ c: Choice) {
        HapticManager.shared.tap()
        withAnimation(.spring(response: 0.3)) {
            isOther = c == .other
            switch c {
            case .savings:    source = .savings
            case .bar(let b): source = .bar(b)
            case .jewelry:
                if case .jewelry = source {} else { source = .jewelry(purity: 70) }
            case .other:      source = .bar(.antam)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(loc("gold.src.title")).font(.system(.caption, weight: .medium))
                .foregroundStyle(AppTheme.textSecondary)
            chipGrid(choices, selected: choice, title: title, action: select)

            if case .jewelry(let purity) = source, !isOther {
                Text(loc("gold.src.purity")).font(.system(.caption, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary)
                chipGrid(GoldSource.purities, selected: purity, title: GoldSource.purityLabel) { p in
                    HapticManager.shared.tap()
                    source = .jewelry(purity: p)
                }
            }

            if isOther {
                Text(loc("gold.src.follow")).font(.system(.caption, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary)
                let follows: [GoldSource] = [.bar(.antam), .savings, .manual]
                chipGrid(follows, selected: source, title: { f in
                    switch f {
                    case .bar(let b): return b.displayName
                    case .savings:    return loc("gold.src.savings_short")
                    default:          return loc("gold.src.manual")
                    }
                }) { f in
                    HapticManager.shared.tap()
                    source = f
                }
            }

            Text(note)
                .font(.system(.caption2))
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var note: String {
        if isOther {
            return source == .manual ? loc("gold.note.manual") : loc("gold.note.other")
        }
        switch source {
        case .savings, .manual: return loc("gold.note.savings")
        case .bar:              return loc("gold.note.bar")
        case .jewelry:          return String(format: loc("gold.note.jewelry"),
                                              Int((GoldPricing.jewelryCut * 100).rounded()))
        }
    }

    private func chipGrid<T: Hashable>(_ items: [T], selected: T, title: @escaping (T) -> String,
                                       action: @escaping (T) -> Void) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(items, id: \.self) { item in
                Button { action(item) } label: {
                    Text(title(item))
                        .font(.system(.caption, weight: .semibold))
                        .foregroundStyle(item == selected ? AppTheme.onVividFill : AppTheme.textSecondary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(item == selected ? AppTheme.accent : idle, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
