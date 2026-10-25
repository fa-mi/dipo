import SwiftUI

// MARK: - Pictures for the Tap to Log walkthrough
//
// What Shortcuts and Settings show at each step of the setups in
// BackTapGuideView, drawn under the step that asks for it. Drawn rather than
// screenshotted: a drawing stays sharp, follows light and dark, and carries no
// bank's logo. The words are the ones the steps use, so a picture and its step
// always agree; DiPo's own actions read in English everywhere, as Shortcuts
// shows them. A green ring marks what to tap.

enum GuidePicture: View {
    // The screenshot shortcut, on Back Tap's double tap.
    /// My Shortcuts, with + to start a new one.
    case newShortcut
    /// Take Screenshot in the action search.
    case takeScreenshot
    /// DiPo's action under Take Screenshot, its blank filled with the
    /// screenshot.
    case logFromScreenshot
    /// The shortcut named, and Done.
    case nameAndSave
    /// Back Tap's settings, the row the step binds ringed.
    case backTap(triple: Bool)

    // The voice shortcut, on Back Tap's triple tap.
    /// One of DiPo's actions in the action search.
    case dipoAction(String)
    /// A sentence said out loud, and the entries it becomes.
    case voiceTalk

    // The notification automation.
    /// The trigger, with + to add the payment apps.
    case trigger
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
            case .newShortcut: newShortcutPicture
            case .takeScreenshot: takeScreenshotPicture
            case .logFromScreenshot: logFromScreenshotPicture
            case .nameAndSave: nameAndSavePicture
            case .backTap(let triple): backTapPicture(triple: triple)
            case .dipoAction(let title): dipoActionPicture(title)
            case .voiceTalk: voiceTalkPicture
            case .trigger: triggerPicture
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

    // MARK: The screenshot shortcut

    private var newShortcutPicture: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(loc("tappic.my_shortcuts")).font(.system(.subheadline, weight: .bold))
                Spacer(minLength: 8)
                Image(systemName: "plus")
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(AppTheme.blue)
                    .frame(width: 26, height: 26)
                    .background(AppTheme.cardDark, in: Circle())
                    .tapHere(corner: 13)
            }
            HStack(spacing: 8) {
                ShortcutTile(tint: AppTheme.blue)
                ShortcutTile(tint: AppTheme.orange)
            }
        }
    }

    private var takeScreenshotPicture: some View {
        VStack(spacing: 8) {
            SearchField(text: loc("tappic.take_screenshot"))
            ResultRow(title: loc("tappic.take_screenshot")) { ScreenshotActionIcon() }
                .tapHere(corner: 10)
        }
    }

    private var logFromScreenshotPicture: some View {
        VStack(spacing: 0) {
            TakeScreenshotCard()
            FlowLine()
            VariableBubble(text: loc("tappic.screenshot"), glyph: "photo")
            FlowLine()
            LogFromScreenshotCard(ringed: true)
        }
    }

    private var nameAndSavePicture: some View {
        VStack(spacing: 8) {
            HStack {
                HStack(spacing: 4) {
                    Text(loc("tappic.shortcut_name")).fontWeight(.semibold)
                    Image(systemName: "chevron.down")
                        .font(.system(.caption2, weight: .bold))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 9))
                Spacer(minLength: 8)
                Text(loc("tappic.done"))
                    .fontWeight(.bold)
                    .foregroundStyle(AppTheme.blue)
                    .padding(.horizontal, 12).padding(.vertical, 4)
                    .background(AppTheme.cardDark, in: Capsule())
                    .tapHere(corner: 13)
            }
            VStack(spacing: 6) {
                TakeScreenshotCard()
                LogFromScreenshotCard(ringed: false)
            }
            .opacity(0.6)
        }
    }

    private func backTapPicture(triple: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(loc(triple ? "tappic.back_tap" : "tappic.settings_path"))
                .font(.system(.caption2))
                .foregroundStyle(AppTheme.textSecondary)
            ShortcutCard {
                VStack(spacing: 0) {
                    SettingRow(label: loc("tappic.double_tap"), value: loc("tappic.shortcut_name"),
                               ringed: !triple)
                    Divider().overlay(AppTheme.cardMid)
                    SettingRow(label: loc("tappic.triple_tap"),
                               value: loc(triple ? "tappic.log_with_voice" : "tappic.none"),
                               ringed: triple)
                }
            }
        }
    }

    // MARK: The voice shortcut

    private func dipoActionPicture(_ title: String) -> some View {
        VStack(spacing: 8) {
            SearchField(text: "DiPo")
            ResultRow(title: title, app: "DiPo") { DiPoActionIcon() }
                .tapHere(corner: 10)
        }
    }

    private var voiceTalkPicture: some View {
        VStack(alignment: .trailing, spacing: 8) {
            HStack(alignment: .top, spacing: 5) {
                Image(systemName: "waveform")
                Text(verbatim: "\u{201C}" + loc("tappic.voice_said") + "\u{201D}")
            }
            .font(.system(.caption, weight: .semibold))
            .foregroundStyle(AppTheme.onVividFill)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(AppTheme.accentFill,
                        in: UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 14,
                                                   bottomTrailingRadius: 4, topTrailingRadius: 14))
            .padding(.leading, 30)
            ShortcutCard {
                VStack(spacing: 0) {
                    SpokenRow(category: .food, name: loc("tappic.voice_lunch"), amount: 45_000)
                    Divider().overlay(AppTheme.cardMid)
                    SpokenRow(category: .transport, name: loc("tappic.voice_parking"), amount: 5_000)
                }
            }
        }
    }

    // MARK: The notification automation

    private var triggerPicture: some View {
        VStack(spacing: 0) {
            TriggerCard(apps: ["BRImo", "GoPay", "DANA"], ringOnArrow: false)
            FlowLine()
            VariableBubble()
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
    /// What a variable comes from: a notification's bell, a screenshot.
    var glyph = "bell.fill"

    var body: some View {
        HStack(spacing: 3) {
            if kind == .variable {
                Image(systemName: glyph).imageScale(.small)
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

/// What a step hands on, drawn under it: the trigger's Notification, Take
/// Screenshot's Screenshot.
private struct VariableBubble: View {
    /// The trigger's Notification when nil.
    var text: String? = nil
    var glyph = "bell.fill"

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: glyph).imageScale(.small)
            Text(verbatim: text ?? loc("notifpic.notification")).fontWeight(.semibold)
        }
        .foregroundStyle(AppTheme.blue)
        .padding(.horizontal, 9).padding(.vertical, 3)
        .background(AppTheme.blue.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// A shortcut already in the library, its name left out.
private struct ShortcutTile: View {
    let tint: Color

    var body: some View {
        VStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.55)).frame(width: 16, height: 16)
            Spacer(minLength: 8)
            Capsule().fill(.white.opacity(0.45)).frame(width: 50, height: 6)
        }
        .padding(7)
        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
        .background(tint.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// The search field over Shortcuts' list of actions.
private struct SearchField: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(AppTheme.textSecondary)
            Text(verbatim: text)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// An action in the search results, with + to add it.
private struct ResultRow<Icon: View>: View {
    let title: String
    var app: String? = nil
    @ViewBuilder var icon: Icon

    var body: some View {
        HStack(spacing: 8) {
            icon
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: title).fontWeight(.semibold)
                if let app {
                    Text(verbatim: app).font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "plus.circle.fill").font(.system(.body)).foregroundStyle(AppTheme.blue)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Shortcuts' own Take Screenshot, as its icon reads.
private struct ScreenshotActionIcon: View {
    var body: some View {
        Image(systemName: "camera.viewfinder")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(AppTheme.slate, in: RoundedRectangle(cornerRadius: 5))
    }
}

/// The shortcut's first action.
private struct TakeScreenshotCard: View {
    var body: some View {
        ShortcutCard {
            HStack(spacing: 6) {
                ScreenshotActionIcon()
                Text(loc("tappic.take_screenshot")).fontWeight(.semibold)
            }
        }
    }
}

/// DiPo's action under it, its blank holding the screenshot.
private struct LogFromScreenshotCard: View {
    let ringed: Bool

    var body: some View {
        ShortcutCard {
            HStack(spacing: 6) {
                DiPoActionIcon()
                Text(loc("tappic.log_from")).fontWeight(.semibold)
                if ringed {
                    screenshot.tapHere(corner: 6)
                } else {
                    screenshot
                }
            }
        }
    }

    private var screenshot: Pill {
        Pill(text: loc("tappic.screenshot"), kind: .variable, glyph: "photo")
    }
}

/// A row of Back Tap's settings: the tap, and the shortcut it runs.
private struct SettingRow: View {
    let label: String
    let value: String
    let ringed: Bool

    var body: some View {
        if ringed {
            row.tapHere(corner: 8)
        } else {
            row
        }
    }

    private var row: some View {
        HStack {
            Text(verbatim: label)
            Spacer(minLength: 8)
            Text(verbatim: value + " \u{203A}").foregroundStyle(AppTheme.textSecondary)
        }
        .padding(.vertical, 6)
    }
}

/// One entry DiPo made from the sentence, as the confirm card lists it.
private struct SpokenRow: View {
    let category: TxCategory
    let name: String
    let amount: Double

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: category.icon)
                .font(.system(.caption2, weight: .semibold))
                .foregroundStyle(category.color)
                .frame(width: 22, height: 22)
                .background(category.color.opacity(0.16), in: RoundedRectangle(cornerRadius: 7))
            Text(verbatim: name)
            Spacer(minLength: 8)
            Text(CurrencyManager.shared.formatted(amount, currency: "IDR")).fontWeight(.semibold)
        }
        .padding(.vertical, 5)
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
