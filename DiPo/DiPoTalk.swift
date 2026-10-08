import SwiftUI
import AVFoundation

// MARK: - DiPo talks
//
// On Home, DiPo stands at the top in his own frame. His speech bubble
// reminds about unread notifications, a bill falling due and payday — and
// replaces the banners that used to say the same; tapping DiPo opens Ask DiPo.
//
// In Ask DiPo he opens the conversation with the Smart Insights, most urgent
// first, in place of the flat banners Home used to show. Free hears the top
// insight; the rest wait behind Royal, which can also chat by text or voice.
// With no insight to give, he passes on a money tip of the day.
//
// The figures are the Smart Budget engine's own: DiPo only says them.

/// One thing DiPo says.
struct DiPoLine: Identifiable, Equatable {
    enum Action {
        case notifications
        case insight(SmartInsightAction.Kind?)
        case royal
        case none
    }

    let id: String
    let mood: DiPoMood
    let exclamation: String
    /// Bold first line; empty when the line is a single sentence.
    let title: String
    let text: String
    let action: Action

    static func == (a: DiPoLine, b: DiPoLine) -> Bool { a.id == b.id }

    /// Whether tapping the bubble goes anywhere.
    var opens: Bool {
        if case .none = action { return false }
        return true
    }
}

enum DiPoScript {
    static let tipCount = 7

    /// What DiPo has to say, in the order he says it.
    static func lines(unread: Int, insights: [SmartInsight], isRoyal: Bool,
                      day: Date = .now, calendar: Calendar = .current) -> [DiPoLine] {
        var out: [DiPoLine] = []
        if unread > 0 {
            out.append(DiPoLine(
                id: "unread-\(unread)", mood: .info, exclamation: loc("dipo.sfx.psst"), title: "",
                text: unread == 1 ? loc("dipo.unread_one") : String(format: loc("dipo.unread_many"), unread),
                action: .notifications))
        }

        let said = insights.map { insight in
            DiPoLine(id: "insight-\(insight.title)", mood: mood(of: insight),
                     exclamation: exclamation(for: mood(of: insight)),
                     title: insight.title, text: insight.body,
                     action: .insight(insight.action?.kind))
        }
        if said.isEmpty {
            out.append(tip(on: day, calendar: calendar))
        } else if isRoyal {
            out.append(contentsOf: said)
        } else {
            out.append(said[0])
            if said.count > 1 {
                out.append(DiPoLine(id: "royal-\(said.count)", mood: .info,
                                    exclamation: loc("dipo.sfx.tomorrow"), title: "",
                                    text: String(format: loc("dipo.locked"), said.count - 1),
                                    action: .royal))
            }
        }
        return out
    }

    /// A warning colour means a warning; green is good news; anything else is news.
    static func mood(of insight: SmartInsight) -> DiPoMood {
        if insight.color == AppTheme.red || insight.color == AppTheme.orange { return .worry }
        if insight.color == AppTheme.accent { return .happy }
        return .info
    }

    static func exclamation(for mood: DiPoMood) -> String {
        switch mood {
        case .happy:        return loc("dipo.sfx.happy")
        case .worry:        return loc("dipo.sfx.worry")
        case .cheer:        return loc("dipo.sfx.cheer")
        case .info, .idle:  return loc("dipo.sfx.info")
        }
    }

    /// The tip of the day: the same all day, a different one tomorrow.
    static func tip(on day: Date, calendar: Calendar = .current) -> DiPoLine {
        let n = (calendar.ordinality(of: .day, in: .era, for: day) ?? 0) % tipCount
        return DiPoLine(id: "tip-\(n)", mood: .happy, exclamation: loc("dipo.sfx.tip"), title: "",
                        text: loc("dipo.tip.\(n)"), action: .none)
    }
}

// MARK: - DiPo's voice

/// DiPo saying his replies aloud, in the app's language.
@MainActor
final class DiPoVoice {
    /// Suggested questions in Ask DiPo: `dipo.q.0` … `dipo.q.<count-1>`.
    static let questionCount = 4
    private let synth = AVSpeechSynthesizer()

    func speak(_ text: String) {
        synth.stopSpeaking(at: .immediate)
        // Dictation may have left the session recording; replies need playback.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: Self.voiceLanguage)
        utterance.pitchMultiplier = 1.15
        synth.speak(utterance)
    }

    func stop() { synth.stopSpeaking(at: .immediate) }

    static var voiceLanguage: String {
        LanguageManager.shared.currentLocale.identifier.hasPrefix("id") ? "id-ID" : "en-US"
    }

    /// Roughly how long the text takes to say, so DiPo nods for that long.
    static func estimatedSeconds(_ text: String) -> Double {
        min(20, max(1, Double(text.count) * 0.065))
    }
}

// MARK: - Home: DiPo at the top

/// Something DiPo's bubble on Home reminds about.
struct DiPoNudge: Equatable, Identifiable {
    enum Action: Equatable {
        case notifications, checkIn, bills, salary, streak
        /// "You like your coffee, don't you?" — answered in a dialog.
        case interestGuess(DiPoInterest)
        /// A confirmed interest: opens Ask DiPo with its question.
        case interestTip(DiPoInterest)
        /// Today's DiPo Quest has not been played yet.
        case quest
    }
    let id: String
    let mood: DiPoMood
    let exclamation: String
    let text: String
    let action: Action
    /// The tap-through under the text: "Tap to read ›".
    let link: String

    /// Bills and payday are mentioned from this many days out.
    static let window = 3

    /// A bill DiPo can mention, without tying this to the model type.
    struct Bill: Equatable {
        let label: String
        let amount: String
        let daysLeft: Int
        let autoRecord: Bool
        /// The paying card's balance once the bill is out, formatted.
        var balanceAfter: String? = nil
    }

    /// Everything worth a reminder, most pressing first: unread notifications,
    /// then a bill falling due within three days, then payday from three days
    /// out. Empty means DiPo just invites a question.
    static func all(unread: Int, checkIn: Bool = false, streak: Int = 0,
                    bill: Bill?, daysToPayday: Int?, payDate: Date?,
                    interestGuess: DiPoInterest? = nil, interestTip: DiPoInterest? = nil,
                    questWaiting: Bool = false) -> [DiPoNudge] {
        var out: [DiPoNudge] = []
        // The streak greets the user when they open the app; two days is the
        // shortest run worth a word.
        if streak >= 2 {
            let body: String
            switch streak {
            case 100...: body = loc("dipo.streak_legend")
            case 30...:  body = loc("dipo.streak_month")
            case 7...:   body = loc("dipo.streak_week")
            default:     body = loc("dipo.streak_keep")
            }
            out.append(DiPoNudge(id: "streak-\(streak)", mood: .cheer,
                                 exclamation: String(format: loc("dipo.streak_title"), streak),
                                 text: body, action: .streak, link: loc("dipo.link.streak")))
        }
        if unread > 0 {
            out.append(DiPoNudge(id: "unread-\(unread)", mood: .info, exclamation: loc("dipo.sfx.psst"),
                                 text: unread == 1 ? loc("dipo.unread_one") : String(format: loc("dipo.unread_many"), unread),
                                 action: .notifications, link: loc("dipo.link.notifications")))
        }
        // The evening check-in: nothing logged today yet.
        if checkIn {
            out.append(DiPoNudge(id: "checkin", mood: .info, exclamation: loc("checkin.ask_title"),
                                 text: loc("checkin.ask_body"), action: .checkIn, link: loc("dipo.link.checkin")))
        }
        if let bill, bill.daysLeft >= 0, bill.daysLeft <= window {
            let when: String
            switch bill.daysLeft {
            case 0:  when = String(format: loc("dipo.bill_today"), bill.label, bill.amount)
            case 1:  when = String(format: loc("dipo.bill_tomorrow"), bill.label, bill.amount)
            default: when = String(format: loc("dipo.bill_in"), bill.label, bill.amount, bill.daysLeft)
            }
            // The balance afterwards says more than "make sure it covers it".
            let then = bill.balanceAfter.map { String(format: loc("dipo.bill_balance_after"), $0) }
                ?? loc(bill.autoRecord ? "dipo.bill_auto" : "dipo.bill_manual")
            out.append(DiPoNudge(id: "bill-\(bill.label)-\(bill.daysLeft)", mood: bill.daysLeft == 0 ? .worry : .info,
                                 exclamation: loc("dipo.sfx.bill"), text: when + " " + then,
                                 action: .bills, link: loc("dipo.link.bills")))
        }
        if let days = daysToPayday, days >= 0, days <= window {
            let date = payDate.map(Self.day) ?? ""
            let text: String
            switch days {
            case 0:  text = loc("dipo.payday_today")
            case 1:  text = String(format: loc("dipo.payday_tomorrow"), date)
            default: text = String(format: loc("dipo.payday_in"), days, date)
            }
            out.append(DiPoNudge(id: "payday-\(days)", mood: days == 0 ? .cheer : .happy,
                                 exclamation: loc(days == 0 ? "dipo.sfx.payday_today" : "dipo.sfx.payday_soon"),
                                 text: text, action: .salary, link: loc("dipo.link.salary")))
        }
        // Getting to know the user comes after anything with money or a date
        // attached: first a guess to confirm, then ideas for what they enjoy.
        if let guess = interestGuess {
            out.append(DiPoNudge(id: "interest-ask-\(guess.rawValue)", mood: .happy,
                                 exclamation: guess.question, text: loc("interest.ask_body"),
                                 action: .interestGuess(guess), link: loc("interest.link_answer")))
        }
        if let tip = interestTip {
            out.append(DiPoNudge(id: "interest-tip-\(tip.rawValue)", mood: .happy,
                                 exclamation: String(format: loc("interest.tip_title"), tip.emoji),
                                 text: loc("interest.\(tip.rawValue).tip"),
                                 action: .interestTip(tip), link: loc("interest.link_ask")))
        }
        // Last of all: a nudge back to the game, whose daily quests include
        // logging a transaction — the habit the rest of the app is for.
        if questWaiting {
            out.append(DiPoNudge(id: "quest", mood: .happy, exclamation: loc("dipo.quest_title"),
                                 text: loc("dipo.quest_body"), action: .quest, link: loc("dipo.link.quest")))
        }
        return out
    }

    /// The first of `all` — what the bubble shows before any paging.
    static func pick(unread: Int, daysToPayday: Int?, payDate: Date?) -> DiPoNudge? {
        all(unread: unread, bill: nil, daysToPayday: daysToPayday, payDate: payDate).first
    }

    private static func day(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = LanguageManager.shared.currentLocale
        f.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return f.string(from: d)
    }
}

/// DiPo under Home's header: his speech bubble on the left, pointing at him
/// in his own frame on the right — across from the profile picture, so the
/// two never stack. The bubble reminds (one thing at a time, with a pager when
/// there are more); with nothing to remind, it invites a question. Tapping
/// DiPo opens Ask DiPo.
struct DiPoHomeStrip: View {
    let nudges: [DiPoNudge]
    /// Today in a few words ("Today is logged"), when there is no reminder.
    var status: String? = nil
    var onAskDiPo: () -> Void
    var onNudge: (DiPoNudge.Action) -> Void
    /// False while Ask DiPo covers Home, so this DiPo stops drawing.
    var animates = true

    @State private var page = 0
    private var current: DiPoNudge? { nudges.isEmpty ? nil : nudges[min(page, nudges.count - 1)] }

    var body: some View {
        let card = RoundedRectangle(cornerRadius: 22, style: .continuous)
        HStack(alignment: .center, spacing: 0) {
            bubble
            DiPoDragonView(mood: current?.mood ?? .idle, line: current?.id ?? "home", onTap: onAskDiPo,
                           animates: animates)
                .frame(width: 112, height: 120)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(loc("mascot.a11y"))
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(loc("dipo.a11y_ask"))
                .accessibilityAction { onAskDiPo() }
        }
        .padding(.leading, 10).padding(.vertical, 8)
        // His own card: a green wash and hairline, so he and what he says
        // read as one thing on the page.
        .background {
            card.fill(AppTheme.bg)
                .overlay(card.fill(LinearGradient(colors: [AppTheme.accent.opacity(0.18), AppTheme.accent.opacity(0.03)],
                                                  startPoint: .topLeading, endPoint: .bottomTrailing)))
        }
        .overlay(card.stroke(AppTheme.accent.opacity(0.35), lineWidth: 1))
        .onChange(of: nudges.map(\.id)) { _, _ in page = 0 }
        .animation(.spring(response: 0.35), value: current?.id)
    }

    private var bubble: some View {
        Button {
            HapticManager.shared.tap()
            if let current { onNudge(current.action) } else { onAskDiPo() }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                if let current {
                    Text(current.exclamation)
                        .font(.system(.footnote, weight: .bold))
                        .foregroundStyle(AppTheme.royalGoldText)
                        .lineLimit(2)
                    Text(current.text)
                        .font(.system(.caption))
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(current.link + " \u{203A}")
                        .font(.system(.caption, weight: .semibold))
                        .foregroundStyle(AppTheme.accent)
                        .padding(.top, 2)
                        .padding(.trailing, nudges.count > 1 ? 40 : 0)
                } else {
                    Text(status ?? loc("dipo.ask"))
                        .font(.system(.footnote, weight: .bold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(loc("dipo.home_invite"))
                        .font(.system(.caption))
                        .foregroundStyle(AppTheme.textSecondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 18).padding(.vertical, 16)
            .padding(.trailing, 16 + CloudBubble.tailRoom)
            .background(CloudBubble())
            .id(current?.id ?? "invite")
            .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .trailing)))
        }
        .buttonStyle(ScaleButtonStyle())
        .accessibilityHint(current == nil ? loc("dipo.a11y_ask") : loc("dipo.a11y_open"))
        // A pager for the other reminders — outside the bubble's own button,
        // so each tap goes where it looks like it goes.
        .overlay(alignment: .bottomTrailing) {
            if nudges.count > 1 {
                Button {
                    HapticManager.shared.tap()
                    withAnimation(.spring(response: 0.3)) { page = (page + 1) % nudges.count }
                } label: {
                    Text(verbatim: "\(min(page, nudges.count - 1) + 1)/\(nudges.count) \u{203A}")
                        .font(.system(.caption2, weight: .bold).monospacedDigit())
                        .foregroundStyle(AppTheme.textSecondary)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(AppTheme.cardMid, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 14 + CloudBubble.tailRoom).padding(.bottom, 14)
                .accessibilityLabel(loc("dipo.next"))
            }
        }
    }
}

/// A manga thought cloud: a soft body ringed with bumps, and two little
/// puffs trailing off towards DiPo on the right. Drawn as circles — each
/// bump stroked, then the whole cloud filled over them — so only the outer
/// edge of the outline shows and the bumps join without seams.
struct CloudBubble: View {
    /// Width kept on the trailing side for the puffs.
    static let tailRoom: CGFloat = 18
    var bump: CGFloat = 10
    var fill: Color = AppTheme.cardDark
    var line: Color = AppTheme.royalGold.opacity(0.6)

    var body: some View {
        Canvas { ctx, size in
            let body = CGRect(x: 0, y: 0, width: size.width - Self.tailRoom, height: size.height)
            let bumps = Self.bumps(in: body, radius: bump)
            let puffs: [(CGPoint, CGFloat)] = [
                (CGPoint(x: body.maxX + 3, y: body.midY + body.height * 0.18), 5.5),
                (CGPoint(x: body.maxX + 12, y: body.midY + body.height * 0.3), 3.5),
            ]
            var outline = Path()
            var cloud = Path()
            for p in bumps {
                let r = CGRect(x: p.x - bump, y: p.y - bump, width: bump * 2, height: bump * 2)
                outline.addEllipse(in: r)
                cloud.addEllipse(in: r)
            }
            cloud.addRect(body.insetBy(dx: bump * 0.6, dy: bump * 0.6))
            ctx.stroke(outline, with: .color(line), lineWidth: 2.4)
            ctx.fill(cloud, with: .color(fill))
            for (c, r) in puffs {
                let e = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
                ctx.stroke(e, with: .color(line), lineWidth: 1.4)
                ctx.fill(e, with: .color(fill))
            }
        }
        .accessibilityHidden(true)
    }

    /// Bump centres, evenly spaced around the body inset by a bump's radius,
    /// so the bumps form the edge and stay inside the frame.
    static func bumps(in rect: CGRect, radius r: CGFloat) -> [CGPoint] {
        // r + 1.5 keeps the outline's outer half inside the canvas.
        let inner = rect.insetBy(dx: r + 1.5, dy: r + 1.5)
        guard inner.width > 0, inner.height > 0 else { return [] }
        let perimeter = 2 * (inner.width + inner.height)
        let count = max(8, Int((perimeter / (r * 1.4)).rounded()))
        return (0..<count).map { i in
            var d = CGFloat(i) * perimeter / CGFloat(count)
            if d < inner.width { return CGPoint(x: inner.minX + d, y: inner.minY) }
            d -= inner.width
            if d < inner.height { return CGPoint(x: inner.maxX, y: inner.minY + d) }
            d -= inner.height
            if d < inner.width { return CGPoint(x: inner.maxX - d, y: inner.maxY) }
            d -= inner.width
            return CGPoint(x: inner.minX, y: inner.maxY - d)
        }
    }
}

/// DiPo's own little stage: a rounded frame with a soft green glow and a
/// gold hairline, so he has room around him instead of floating on the page.
struct DiPoFrame<Content: View>: View {
    let size: CGFloat?
    var cornerRadius: CGFloat = 26
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack(alignment: .bottom) {
            shape.fill(RadialGradient(colors: [AppTheme.accent.opacity(0.22), AppTheme.cardDark],
                                      center: UnitPoint(x: 0.5, y: 0.38), startRadius: 0,
                                      endRadius: (size ?? 220) * 0.72))
            // A soft floor under him.
            Ellipse()
                .fill(RadialGradient(colors: [.black.opacity(0.18), .clear], center: .center, startRadius: 0, endRadius: 24))
                .frame(width: 48, height: 9)
                .padding(.bottom, 9)
            content.padding(8)
        }
        .frame(width: size, height: size)
        .background(shape.fill(AppTheme.cardDark))
        .clipShape(shape)
        .overlay(shape.stroke(AppTheme.royalGold.opacity(0.45), lineWidth: 1))
        .shadow(color: .black.opacity(0.07), radius: 10, y: 5)
    }
}

// MARK: - DiPo's bubble

extension View {
    /// DiPo's speech bubble: the card colour, a gold hairline and a soft
    /// shadow, so it sits with the rest of the app. `tail` points it at DiPo.
    func dipoBubble(tail: BubbleShape.Tail = .none, hairline: Color = AppTheme.royalGold) -> some View {
        let shape = BubbleShape(tail: tail)
        return self
            .background {
                shape.fill(AppTheme.cardDark)
                    .shadow(color: .black.opacity(0.07), radius: 10, x: 0, y: 5)
            }
            .overlay {
                shape.stroke(hairline.opacity(0.45), style: StrokeStyle(lineWidth: 1, lineJoin: .round))
            }
    }
}

/// A rounded bubble drawn as one outline, so the tail joins the body without
/// a seam. The tail, when there is one, takes the last (or first) `tail`
/// points of the width, at the middle of that edge.
struct BubbleShape: Shape {
    enum Tail { case none, leading, trailing }
    static let tail: CGFloat = 10
    var tail: Tail = .none

    func path(in rect: CGRect) -> Path {
        let minX = rect.minX + (tail == .leading ? Self.tail : 0)
        let maxX = rect.maxX - (tail == .trailing ? Self.tail : 0)
        let minY = rect.minY, maxY = rect.maxY, mid = rect.midY
        let r = min(20, rect.height / 2)
        var p = Path()
        p.move(to: CGPoint(x: minX + r, y: minY))
        p.addLine(to: CGPoint(x: maxX - r, y: minY))
        p.addArc(center: CGPoint(x: maxX - r, y: minY + r), radius: r, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        if tail == .trailing {
            p.addLine(to: CGPoint(x: maxX, y: mid - 8))
            p.addQuadCurve(to: CGPoint(x: rect.maxX, y: mid), control: CGPoint(x: maxX + 2, y: mid - 3))
            p.addQuadCurve(to: CGPoint(x: maxX, y: mid + 8), control: CGPoint(x: maxX + 2, y: mid + 3))
        }
        p.addLine(to: CGPoint(x: maxX, y: maxY - r))
        p.addArc(center: CGPoint(x: maxX - r, y: maxY - r), radius: r, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: minX + r, y: maxY))
        p.addArc(center: CGPoint(x: minX + r, y: maxY - r), radius: r, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        if tail == .leading {
            p.addLine(to: CGPoint(x: minX, y: mid + 8))
            p.addQuadCurve(to: CGPoint(x: rect.minX, y: mid), control: CGPoint(x: minX - 2, y: mid + 3))
            p.addQuadCurve(to: CGPoint(x: minX, y: mid - 8), control: CGPoint(x: minX - 2, y: mid - 3))
        }
        p.addLine(to: CGPoint(x: minX, y: minY + r))
        p.addArc(center: CGPoint(x: minX + r, y: minY + r), radius: r, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }
}
