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
    enum Action: Equatable { case notifications, checkIn, bills, salary, streak }
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
    }

    /// Everything worth a reminder, most pressing first: unread notifications,
    /// then a bill falling due within three days, then payday from three days
    /// out. Empty means DiPo just invites a question.
    static func all(unread: Int, checkIn: Bool = false, streak: Int = 0,
                    bill: Bill?, daysToPayday: Int?, payDate: Date?) -> [DiPoNudge] {
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
            let then = loc(bill.autoRecord ? "dipo.bill_auto" : "dipo.bill_manual")
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
        HStack(alignment: .center, spacing: 10) {
            bubble
            DiPoFrame(size: 92) {
                DiPoDragonView(mood: current?.mood ?? .idle, line: current?.id ?? "home", onTap: onAskDiPo,
                               animates: animates)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(loc("mascot.a11y"))
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(loc("dipo.a11y_ask"))
            .accessibilityAction { onAskDiPo() }
        }
        .onChange(of: nudges.map(\.id)) { _, _ in page = 0 }
        .animation(.spring(response: 0.35), value: current?.id)
    }

    private var bubble: some View {
        Button {
            HapticManager.shared.tap()
            if let current { onNudge(current.action) } else { onAskDiPo() }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                if let current {
                    Text(current.exclamation)
                        .font(.system(.headline, design: .serif, weight: .semibold).italic())
                        .foregroundStyle(AppTheme.royalGoldText)
                    Text(current.text)
                        .font(.system(.footnote))
                        .foregroundStyle(AppTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(current.link + " \u{203A}")
                        .font(.system(.caption, weight: .semibold))
                        .foregroundStyle(AppTheme.accent)
                        .padding(.top, 3)
                        .padding(.trailing, nudges.count > 1 ? 44 : 0)
                } else {
                    Text(status ?? loc("dipo.ask"))
                        .font(.system(.subheadline, weight: .bold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(loc("dipo.home_invite"))
                        .font(.system(.caption))
                        .foregroundStyle(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 16).padding(.trailing, 16 + BubbleShape.tail).padding(.vertical, 12)
            .dipoBubble(tail: .trailing)
            .id(current?.id ?? "invite")
            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .trailing)))
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
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(AppTheme.cardMid, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 14 + BubbleShape.tail).padding(.bottom, 10)
                .accessibilityLabel(loc("dipo.next"))
            }
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
