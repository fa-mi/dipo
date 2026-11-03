import SwiftUI

// MARK: - The add-transaction form, as rows
//
// The form used to stack a row of category tiles, a swipeable card, two
// boxed date pickers and a boxed notes field, each under its own heading.
// Now the amount is big and centred, and category, account, date and note
// are four plain rows: what it is on the left, its value on the right. A row
// with more to choose from opens it.

/// One line of the form: an icon in its colour, what it is, and its value.
struct TxFormRow<Value: View>: View {
    let icon: String
    var tint: Color = AppTheme.textSecondary
    let title: String
    var chevron = false
    @ViewBuilder var value: Value

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(.body, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(.subheadline))
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize()
            Spacer(minLength: 8)
            value
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

/// Every category at once, in a grid: tap one and the sheet closes. The
/// chosen one sits on a plain fill, which marks the choice.
struct CategoryGridSheet: View {
    let categories: [TxCategory]
    @Binding var selection: TxCategory
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 78), spacing: 8)], spacing: 8) {
                        ForEach(categories, id: \.self) { cat in
                            let on = selection == cat
                            Button {
                                HapticManager.shared.select()
                                selection = cat
                                dismiss()
                            } label: {
                                VStack(spacing: 6) {
                                    Image(systemName: cat.icon)
                                        .font(.system(.title3, weight: .semibold))
                                        .foregroundStyle(Color(hex: cat.iconBg))
                                    Text(cat.displayLabel)
                                        .font(.system(.caption, weight: on ? .semibold : .regular))
                                        .foregroundStyle(AppTheme.textPrimary)
                                        .multilineTextAlignment(.center)
                                        .lineLimit(2)
                                        .minimumScaleFactor(0.85)
                                }
                                .frame(maxWidth: .infinity, minHeight: 76)
                                .padding(.horizontal, 4)
                                .background {
                                    if on { RoundedRectangle(cornerRadius: AppRadius.md).fill(AppTheme.cardMid) }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(on ? .isSelected : [])
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .containerRelativeFrame(.horizontal)
                }
            }
            .navigationTitle(loc("common.category"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .doneToolbar { dismiss() }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(AppTheme.bg)
        .preferredColorScheme(appColorScheme())
    }
}

/// The accounts to swipe through, the same pager as before, on a sheet of its
/// own. Done closes it on the one chosen.
struct CardPickSheet: View {
    let cards: [BankCard]
    @Binding var selectedIndex: Int
    let figure: (BankCard) -> (label: String, value: String)
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                AppTheme.bg.ignoresSafeArea()
                CardSwipePicker(cards: cards, selectedIndex: $selectedIndex, figure: figure)
                    .padding(.top, 12)
            }
            .navigationTitle(loc("debt.card"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .doneToolbar { dismiss() }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationBackground(AppTheme.bg)
        .preferredColorScheme(appColorScheme())
    }
}
