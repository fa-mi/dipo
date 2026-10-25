import SwiftUI

// MARK: - Pictures for the notification walkthrough
//
// What Shortcuts shows at each step of the notification automation, drawn
// under the step that asks for it (BackTapGuideView). Drawn rather than
// screenshotted: a drawing stays sharp, follows light and dark, and carries no
// bank's logo. Shortcuts' words appear as an English iPhone shows them, which
// is how DiPo's own action always reads; the steps give the Indonesian names
// beside them. A green ring marks what to tap.

enum NotificationSetupPicture: View {
    /// The trigger, with + to add the payment apps.
    case trigger
    /// DiPo's action in the search results.
    case search
    /// A blank tapped, and the trigger's Notification to tap next.
    case selectVariable
    /// What the Notification in a blank can carry, Title chosen.
    case chooseTitle
    /// Every blank filled.
    case filled
    /// The arrow beside the apps and the switches behind it.
    case runAlone

    var body: some View {
        Group {
            switch self {
            case .trigger: triggerPicture
            case .search: searchPicture
            case .selectVariable: selectVariablePicture
            case .chooseTitle: chooseTitlePicture
            case .filled: filledPicture
            case .runAlone: runAlonePicture
            }
        }
        .font(.system(.caption))
        .foregroundStyle(AppTheme.textPrimary)
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(AppTheme.bg, in: RoundedRectangle(cornerRadius: 14))
        // The step's words say all of it; the picture only shows it.
        .accessibilityHidden(true)
    }

    private var triggerPicture: some View {
        VStack(spacing: 0) {
            TriggerCard(apps: ["BRImo", "GoPay", "DANA"], ringOnArrow: false)
            FlowLine()
            VariableBubble()
        }
    }

    private var searchPicture: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(AppTheme.textSecondary)
                Text(verbatim: "DiPo")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 8) {
                DiPoActionIcon()
                VStack(alignment: .leading, spacing: 1) {
                    Text(loc("notifpic.action")).fontWeight(.semibold)
                    Text(verbatim: "DiPo").font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "plus.circle.fill").font(.system(.body)).foregroundStyle(AppTheme.blue)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 10))
            .tapHere(corner: 10)
        }
    }

    private var selectVariablePicture: some View {
        VStack(spacing: 0) {
            Text(loc("notifpic.select_variable"))
                .font(.system(.caption2, weight: .semibold))
                .foregroundStyle(AppTheme.textSecondary)
                .padding(.bottom, 8)
            VariableBubble().tapHere(2, corner: 8)
            FlowLine()
            ActionCard(filled: false, ringOnTitle: true)
        }
    }

    private var chooseTitlePicture: some View {
        ShortcutCard {
            VStack(alignment: .leading, spacing: 6) {
                SentenceFlow(spacing: 4) {
                    Text(verbatim: "…")
                    Text(loc("notifpic.titled"))
                    Pill(text: loc("notifpic.notification"), kind: .variable)
                }
                PropertyMenu()
                    .padding(.leading, 36)
            }
        }
    }

    private var filledPicture: some View {
        ActionCard(filled: true, ringOnTitle: false)
            .overlay(alignment: .topTrailing) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(.subheadline))
                    .foregroundStyle(AppTheme.accent)
                    .padding(8)
            }
    }

    private var runAlonePicture: some View {
        VStack(spacing: 8) {
            TriggerCard(apps: ["BRImo", "GoPay"], ringOnArrow: true)
            ShortcutCard {
                VStack(spacing: 0) {
                    SwitchRow(label: loc("notifpic.automation"), on: true)
                    Divider().overlay(AppTheme.cardMid)
                    SwitchRow(label: loc("notifpic.confirm"), on: false)
                    Divider().overlay(AppTheme.cardMid)
                    SwitchRow(label: loc("notifpic.locked"), on: true)
                }
            }
        }
    }
}

// MARK: - Pieces

/// A card the way Shortcuts lays out a trigger or an action.
private struct ShortcutCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 11))
    }
}

/// "When I receive a notification from …", with + after the apps and the
/// arrow to its settings.
private struct TriggerCard: View {
    let apps: [String]
    let ringOnArrow: Bool

    var body: some View {
        ShortcutCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "bell.fill").foregroundStyle(AppTheme.red)
                    Text(loc("notifpic.trigger")).fontWeight(.semibold)
                }
                SentenceFlow(spacing: 4) {
                    Text(loc("notifpic.from"))
                    ForEach(apps, id: \.self) { app in
                        Pill(text: app, kind: .app)
                    }
                    if ringOnArrow {
                        Text(verbatim: "…")
                        arrow.tapHere(corner: 10)
                    } else {
                        Image(systemName: "plus")
                            .font(.system(.caption2, weight: .semibold))
                            .foregroundStyle(AppTheme.textSecondary)
                            .frame(width: 20, height: 20)
                            .background(AppTheme.cardMid, in: RoundedRectangle(cornerRadius: 6))
                            .tapHere(corner: 6)
                        arrow
                    }
                }
            }
        }
    }

    private var arrow: some View {
        Image(systemName: "chevron.right.circle")
            .font(.system(.subheadline))
            .foregroundStyle(AppTheme.blue)
    }
}

/// DiPo's action as it reads in a shortcut, its blanks empty or filled.
private struct ActionCard: View {
    let filled: Bool
    let ringOnTitle: Bool

    var body: some View {
        ShortcutCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    DiPoActionIcon()
                    Text(loc("notifpic.summary")).fontWeight(.semibold)
                }
                SentenceFlow(spacing: 4) {
                    Pill(text: loc("notifpic.notification"), kind: .variable)
                    Text(loc("notifpic.titled"))
                    if ringOnTitle {
                        blank("notifpic.title").tapHere(1, corner: 6)
                    } else {
                        blank("notifpic.title")
                    }
                    Text(loc("notifpic.subtitled"))
                    blank("notifpic.subtitle")
                    Text(loc("notifpic.from"))
                    blank("notifpic.app")
                }
            }
        }
    }

    private func blank(_ key: String) -> Pill {
        Pill(text: loc(key), kind: filled ? .variable : .blank)
    }
}

/// A blank or a variable in an action, or an app in the trigger.
private struct Pill: View {
    enum Kind { case variable, blank, app }
    let text: String
    let kind: Kind

    var body: some View {
        HStack(spacing: 3) {
            if kind == .variable {
                Image(systemName: "bell.fill").imageScale(.small)
            }
            Text(verbatim: text).fontWeight(kind == .variable ? .semibold : .regular)
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(kind == .variable ? AppTheme.blue.opacity(0.14) : AppTheme.cardMid,
                    in: RoundedRectangle(cornerRadius: 6))
    }

    private var ink: Color {
        switch kind {
        case .variable: AppTheme.blue
        case .blank: AppTheme.textSecondary.opacity(0.8)
        case .app: AppTheme.textPrimary
        }
    }
}

/// The trigger's output, the variable every blank is filled from.
private struct VariableBubble: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "bell.fill").imageScale(.small)
            Text(loc("notifpic.notification")).fontWeight(.semibold)
        }
        .foregroundStyle(AppTheme.blue)
        .padding(.horizontal, 9).padding(.vertical, 3)
        .background(AppTheme.blue.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// The line Shortcuts draws from one step to the next.
private struct FlowLine: View {
    var body: some View {
        Rectangle().fill(AppTheme.cardMid).frame(width: 2, height: 10)
    }
}

/// What a Notification in a blank can carry, Title chosen.
private struct PropertyMenu: View {
    var body: some View {
        VStack(spacing: 0) {
            row(loc("notifpic.notification"), ink: AppTheme.textSecondary)
            row(loc("notifpic.title"), ink: AppTheme.blue, chosen: true).tapHere(corner: 6)
            row(loc("notifpic.subtitle"))
            row(loc("notifpic.app"))
        }
        .frame(maxWidth: 160)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(AppTheme.cardMid, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
    }

    private func row(_ text: String, ink: Color = AppTheme.textPrimary, chosen: Bool = false) -> some View {
        HStack {
            Text(verbatim: text).fontWeight(chosen ? .semibold : .regular)
            Spacer(minLength: 8)
            if chosen { Image(systemName: "checkmark").font(.system(.caption2, weight: .bold)) }
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 10).padding(.vertical, 5)
    }
}

/// A switch drawn as one, not a control: the picture isn't for tapping.
private struct SwitchRow: View {
    let label: String
    let on: Bool

    var body: some View {
        HStack {
            Text(verbatim: label)
            Spacer(minLength: 8)
            Capsule()
                .fill(on ? AppTheme.accent : AppTheme.cardMid)
                .frame(width: 30, height: 18)
                .overlay(alignment: on ? .trailing : .leading) {
                    Circle().fill(.white).padding(2).shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                }
        }
        .padding(.vertical, 6)
    }
}

/// DiPo's icon as Shortcuts shows it beside the action.
private struct DiPoActionIcon: View {
    var body: some View {
        Image("DiPoMascot")
            .resizable().scaledToFit()
            .frame(width: 33, height: 49)
            .frame(width: 20, height: 20)
            .background(RadialGradient(colors: [AppTheme.accent.opacity(0.35), AppTheme.flowGround],
                                       center: .center, startRadius: 0, endRadius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

/// Words and pills in reading order, wrapping like a sentence.
private struct SentenceFlow: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(of: subviews, width: proposal.width ?? .infinity)
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(of: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(of subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !row.indices.isEmpty, row.width + spacing + size.width > width {
                rows.append(row)
                row = Row()
            }
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

private extension View {
    /// The green ring on what to tap, numbered when there are two.
    func tapHere(_ order: Int? = nil, corner: CGFloat) -> some View {
        padding(3)
            .overlay(RoundedRectangle(cornerRadius: corner + 3).stroke(AppTheme.accent, lineWidth: 2))
            .overlay(alignment: .topTrailing) {
                if let order {
                    Text(verbatim: "\(order)")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(AppTheme.onVividFill)
                        .frame(width: 15, height: 15)
                        .background(AppTheme.accent, in: Circle())
                        .offset(x: 7, y: -7)
                }
            }
    }
}
