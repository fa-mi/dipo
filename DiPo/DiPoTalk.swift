import SwiftUI
import AVFoundation

// MARK: - DiPo talks
//
// On Home, DiPo stands at the top. His comic speech bubble appears only to
// remind about unread notifications; tapping DiPo opens Ask DiPo.
//
// In Ask DiPo he opens the conversation with the Smart Insights, most urgent
// first, in place of the flat banners Home used to show. Free hears the top
// insight; the rest wait behind Royal, which can also chat by text or voice
// and wears the crown. With no insight to give, he passes on a money tip of
// the day.
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

/// DiPo under Home's header. A speech bubble reminds about unread
/// notifications; otherwise a quiet invitation. Tapping DiPo opens Ask DiPo.
struct DiPoHomeStrip: View {
    let unread: Int
    let isRoyal: Bool
    var onAskDiPo: () -> Void
    var onNotifications: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            DiPoDragonView(mood: unread > 0 ? .info : .idle, line: "home-\(unread)",
                           crowned: isRoyal, onTap: onAskDiPo)
                .frame(width: 96, height: 96)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(loc("dipo.a11y_ask"))
            if unread > 0 {
                Button {
                    HapticManager.shared.tap()
                    onNotifications()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(loc("dipo.sfx.psst"))
                            .font(.system(size: 18, weight: .black, design: .rounded).italic())
                            .foregroundStyle(AppTheme.blue)
                        Text(unread == 1 ? loc("dipo.unread_one")
                                         : String(format: loc("dipo.unread_many"), unread))
                            .font(.system(.footnote, weight: .semibold))
                            .foregroundStyle(AppTheme.bubbleInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, BubbleShape.tail + 10).padding(.trailing, 12).padding(.vertical, 10)
                    .comicBubble(tail: true)
                }
                .buttonStyle(ScaleButtonStyle())
                .transition(.scale(scale: 0.8, anchor: .leading).combined(with: .opacity))
            } else {
                Button {
                    HapticManager.shared.tap()
                    onAskDiPo()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(loc("dipo.ask"))
                            .font(.system(.subheadline, weight: .bold))
                            .foregroundStyle(AppTheme.textPrimary)
                        Text(loc("dipo.home_invite"))
                            .font(.system(.caption))
                            .foregroundStyle(AppTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 4)
                }
                .buttonStyle(.plain)
            }
        }
        .animation(.spring(response: 0.35), value: unread)
    }
}

// MARK: - Comic bubble

extension View {
    /// White paper, an ink outline and a hard ink shadow, like a manga panel.
    /// With `tail`, a point on the leading edge toward DiPo.
    func comicBubble(tail: Bool = false) -> some View {
        let shape = BubbleShape(tail: tail)
        return self
            .background {
                ZStack {
                    shape.fill(AppTheme.bubbleInk).offset(x: 3, y: 4)
                    shape.fill(AppTheme.bubbleFill)
                }
            }
            .overlay { shape.stroke(AppTheme.bubbleInk, style: StrokeStyle(lineWidth: 2.5, lineJoin: .round)) }
            .overlay(alignment: .topTrailing) {
                Halftone().frame(width: 56, height: 36).padding(6).allowsHitTesting(false)
            }
    }
}

/// A rounded bubble drawn as one outline, so the tail joins the body without
/// a seam. The tail, when there is one, takes the first `tail` points of the
/// width on the leading edge.
struct BubbleShape: Shape {
    static let tail: CGFloat = 14
    var tail = false

    func path(in rect: CGRect) -> Path {
        let inset: CGFloat = tail ? Self.tail : 0
        let r = min(20, (rect.height) / 2)
        let minX = rect.minX + inset, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        var p = Path()
        p.move(to: CGPoint(x: minX + r, y: minY))
        p.addLine(to: CGPoint(x: maxX - r, y: minY))
        p.addArc(center: CGPoint(x: maxX - r, y: minY + r), radius: r, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: maxX, y: maxY - r))
        p.addArc(center: CGPoint(x: maxX - r, y: maxY - r), radius: r, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: minX + r, y: maxY))
        p.addArc(center: CGPoint(x: minX + r, y: maxY - r), radius: r, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        if tail {
            let mid = rect.midY
            p.addLine(to: CGPoint(x: minX, y: mid + 9))
            p.addQuadCurve(to: CGPoint(x: rect.minX, y: mid + 4), control: CGPoint(x: minX - 4, y: mid + 8))
            p.addQuadCurve(to: CGPoint(x: minX, y: mid - 7), control: CGPoint(x: minX - 6, y: mid - 2))
        }
        p.addLine(to: CGPoint(x: minX, y: minY + r))
        p.addArc(center: CGPoint(x: minX + r, y: minY + r), radius: r, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }
}

/// Manga screentone in the bubble's corner.
private struct Halftone: View {
    var body: some View {
        Canvas { ctx, size in
            let step: CGFloat = 7
            var y: CGFloat = 0
            while y < size.height {
                var x: CGFloat = 0
                while x < size.width {
                    // Denser toward the top right corner.
                    let r = 1.6 * (x / size.width) * (1 - y / size.height)
                    if r > 0.3 {
                        ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                                 with: .color(AppTheme.bubbleInk.opacity(0.18)))
                    }
                    x += step
                }
                y += step
            }
        }
    }
}
