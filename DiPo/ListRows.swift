import SwiftUI

// MARK: - Grouped lists
//
// The minimal screens put related rows on one surface instead of giving each
// row a card of its own: a quiet title above, a hairline between rows, no tile
// behind an icon and no border around anything. The icon keeps its colour,
// because people new to the app find a feature by it. Plan and Profile are
// built from these, so the two tabs read as one system.

enum ListRowMetrics {
    /// Space around a row's contents.
    static let inset: CGFloat = 14
    /// The column the icon sits in, so every title starts on one line.
    static let icon: CGFloat = 28
    /// Between the icon and the words.
    static let gap: CGFloat = 14
}

/// A group of rows on one card, with an optional title above it.
struct ListSection<Rows: View>: View {
    private let title: String?
    private let rows: Rows

    init(_ title: String? = nil, @ViewBuilder rows: () -> Rows) {
        self.title = title
        self.rows = rows()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)
                    .padding(.leading, 4)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(spacing: 0) { rows }
                .frame(maxWidth: .infinity)
                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
        }
    }
}

/// The hairline between two rows. It starts where the words start, or runs
/// edge to edge between rows that have no icon.
struct ListDivider: View {
    var flush = false
    @ScaledMetric(relativeTo: .body) private var icon: CGFloat = ListRowMetrics.icon

    var body: some View {
        Rectangle()
            .fill(AppTheme.cardMid.opacity(0.7))
            .frame(height: 1)
            .padding(.leading, flush ? 0 : ListRowMetrics.inset + icon + ListRowMetrics.gap)
    }
}

/// A row's icon: the glyph in its colour, nothing behind it.
struct ListIcon: View {
    let name: String
    let tint: Color

    var body: some View {
        Image(systemName: name)
            .font(.system(.body, weight: .semibold))
            .foregroundStyle(tint)
    }
}

/// One row: an icon, a title, an optional line under it, and whatever sits at
/// the trailing edge (a chevron, a switch, a verb, the plan a feature needs).
struct ListRow<Leading: View, Trailing: View>: View {
    private let leading: Leading
    private let title: String
    private let subtitle: String?
    private let subtitleTint: Color
    private let subtitleFont: Font
    /// Set for a line that must not wrap, such as one beside a switch, where
    /// a wrap would resize the row while the switch moves.
    private let subtitleLines: Int?
    private let trailing: Trailing
    @ScaledMetric(relativeTo: .body) private var iconColumn: CGFloat = ListRowMetrics.icon

    init(title: String, subtitle: String? = nil,
         subtitleTint: Color = AppTheme.textSecondary,
         subtitleFont: Font = .system(.caption),
         subtitleLines: Int? = nil,
         @ViewBuilder leading: () -> Leading,
         @ViewBuilder trailing: () -> Trailing) {
        self.leading = leading()
        self.title = title
        self.subtitle = subtitle
        self.subtitleTint = subtitleTint
        self.subtitleFont = subtitleFont
        self.subtitleLines = subtitleLines
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: ListRowMetrics.gap) {
            leading
                .frame(width: iconColumn)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    let line = Text(subtitle).font(subtitleFont).foregroundStyle(subtitleTint)
                    if let lines = subtitleLines {
                        line.lineLimit(lines).minimumScaleFactor(0.85)
                    } else {
                        // Without this the Text reports its one-line ideal
                        // width and pushes the row, and the page, wider than
                        // the screen once a line gets long.
                        line.multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(ListRowMetrics.inset)
        .contentShape(Rectangle())
    }
}

extension ListRow where Leading == ListIcon {
    init(icon: String, tint: Color, title: String, subtitle: String? = nil,
         subtitleTint: Color = AppTheme.textSecondary,
         subtitleFont: Font = .system(.caption),
         subtitleLines: Int? = nil,
         @ViewBuilder trailing: () -> Trailing) {
        self.init(title: title, subtitle: subtitle, subtitleTint: subtitleTint,
                  subtitleFont: subtitleFont, subtitleLines: subtitleLines,
                  leading: { ListIcon(name: icon, tint: tint) }, trailing: trailing)
    }
}

extension ListRow where Leading == ListIcon, Trailing == EmptyView {
    init(icon: String, tint: Color, title: String, subtitle: String? = nil) {
        self.init(icon: icon, tint: tint, title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// The trailing chevron of a row that opens something.
struct ListChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(.caption, weight: .semibold))
            .foregroundStyle(AppTheme.textSecondary)
    }
}

/// A verb at a row's trailing edge, such as Edit or Copy. The whole row does
/// it when tapped; the word says what a tap will do.
struct ListAction: View {
    let title: String
    var icon: String? = nil
    var tint: Color = AppTheme.textSecondary

    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon) }
            Text(title)
        }
        .font(.system(.footnote, weight: .semibold))
        .foregroundStyle(tint)
        .fixedSize()
    }
}

/// A full-width word on its own row, for the actions at the bottom of a
/// screen (sign out, erase). Red says the action takes something away.
struct ListButtonLabel: View {
    let title: String
    var tint: Color = AppTheme.red

    var body: some View {
        Text(title)
            .font(.system(.subheadline, weight: .medium))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .contentShape(Rectangle())
    }
}
