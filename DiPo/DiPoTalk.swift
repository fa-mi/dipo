import SwiftUI

// MARK: - DiPo talks
//
// Home's Smart Insights, said by DiPo in a comic speech bubble instead of
// sitting in flat banners. One line at a time: unread notifications first (a
// nudge to go and read them), then the insights, most urgent first. His mood
// follows what he is saying — a hop for good news, a shiver and a sweat drop
// for a warning.
//
// Free hears the top insight; the rest wait behind Royal, which also gets the
// crown and "Ask DiPo". With no insight to give, he passes on a money tip of
// the day, so the bubble is never empty.
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

// MARK: - The card

/// DiPo and his bubble, above the daily check-in.
struct DiPoTalkCard: View {
    let lines: [DiPoLine]
    let isRoyal: Bool
    var onAction: (DiPoLine.Action) -> Void
    var onAsk: () -> Void

    @State private var index = 0
    @State private var shown = 0
    private let calm = UIAccessibility.isReduceMotionEnabled
    private static let perCharacter = 0.025

    private var current: DiPoLine? { lines.isEmpty ? nil : lines[min(index, lines.count - 1)] }
    private var fullText: String { current?.text ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let line = current {
                bubble(line)
                    .padding(.horizontal, 4)
                    .zIndex(1)
            }
            HStack(alignment: .bottom, spacing: 0) {
                DiPoDragonView(mood: current?.mood ?? .idle, line: current?.id ?? "",
                               talkSeconds: calm ? 0 : Double(fullText.count) * Self.perCharacter,
                               crowned: isRoyal)
                    .frame(width: 150, height: 150)
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 8) {
                    if lines.count > 1 {
                        Button {
                            HapticManager.shared.tap()
                            withAnimation(.spring(response: 0.3)) { index = (index + 1) % lines.count }
                        } label: {
                            HStack(spacing: 4) {
                                Text(loc("dipo.next"))
                                Image(systemName: "chevron.right")
                            }
                            .font(.system(.footnote, weight: .bold))
                            .foregroundStyle(AppTheme.onVividFill)
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .background(AppTheme.accentFill, in: Capsule())
                        }
                        .buttonStyle(ScaleButtonStyle())
                        Text(verbatim: "\(index + 1) / \(lines.count)")
                            .font(.system(.caption2, weight: .semibold).monospacedDigit())
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                    if isRoyal {
                        Button {
                            HapticManager.shared.tap()
                            onAsk()
                        } label: {
                            Label(loc("dipo.ask"), systemImage: "bubble.left.and.text.bubble.right")
                                .font(.system(.footnote, weight: .bold))
                                .foregroundStyle(AppTheme.accent)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .overlay(Capsule().stroke(AppTheme.accent, lineWidth: 1.5))
                        }
                        .buttonStyle(ScaleButtonStyle())
                    }
                }
                .padding(.bottom, 12)
            }
            .padding(.top, -14)
        }
        .onChange(of: lines.map(\.id)) { _, _ in index = 0; type() }
        .onChange(of: index) { _, _ in type() }
        .task { type() }
    }

    // MARK: Bubble

    private func bubble(_ line: DiPoLine) -> some View {
        // A quick shake when he has a warning; still otherwise.
        let shake: CGFloat = line.mood == .worry && !calm ? 6 : 0
        return Button {
            HapticManager.shared.tap()
            onAction(line.action)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(line.exclamation)
                    .font(.system(size: 22, weight: .black, design: .rounded).italic())
                    .foregroundStyle(tint(line.mood))
                if !line.title.isEmpty {
                    Text(line.title)
                        .font(.system(.subheadline, weight: .heavy))
                }
                ZStack(alignment: .topLeading) {
                    // The full text, hidden, holds the height so the bubble
                    // does not grow line by line as it types.
                    Text(line.text).opacity(0)
                    Text(String(line.text.prefix(shown)))
                }
                .font(.system(.subheadline, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(AppTheme.bubbleInk)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 14)
            // Room for the tail, inside the shape's frame.
            .padding(.bottom, BubbleShape.tail)
            .background { BubbleShape().fill(AppTheme.bubbleInk).offset(x: 3, y: 4) }
            .background { BubbleShape().fill(AppTheme.bubbleFill) }
            .overlay { BubbleShape().stroke(AppTheme.bubbleInk, lineWidth: 2.5) }
            .overlay(alignment: .topTrailing) { Halftone().frame(width: 70, height: 46).padding(6).allowsHitTesting(false) }
        }
        .buttonStyle(.plain)
        .id(line.id)
        .transition(.scale(scale: 0.85, anchor: .bottomLeading).combined(with: .opacity))
        .keyframeAnimator(initialValue: CGFloat(0), trigger: line.id) { view, x in
            view.offset(x: x)
        } keyframes: { _ in
            KeyframeTrack {
                LinearKeyframe(-shake, duration: 0.06)
                LinearKeyframe(shake, duration: 0.08)
                LinearKeyframe(-shake * 0.7, duration: 0.08)
                LinearKeyframe(shake * 0.5, duration: 0.08)
                LinearKeyframe(0, duration: 0.08)
            }
        }
        .accessibilityLabel([line.title, line.text].filter { !$0.isEmpty }.joined(separator: ". "))
        .accessibilityHint(line.opens ? loc("dipo.a11y_open") : "")
    }

    private func tint(_ mood: DiPoMood) -> Color {
        switch mood {
        case .happy, .cheer: return AppTheme.accent
        case .worry:         return AppTheme.red
        case .info, .idle:   return AppTheme.blue
        }
    }

    /// Types the current line out, a letter at a time.
    private func type() {
        let target = fullText
        guard !calm else { shown = target.count; return }
        shown = 0
        Task { @MainActor in
            for n in 1...max(1, target.count) {
                try? await Task.sleep(for: .seconds(Self.perCharacter))
                guard fullText == target else { return }
                shown = n
            }
        }
    }
}

/// A rounded speech bubble with its tail at the bottom left, toward DiPo.
struct BubbleShape: Shape {
    static let tail: CGFloat = 18

    func path(in rect: CGRect) -> Path {
        let body = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - Self.tail)
        var p = Path(roundedRect: body, cornerRadius: 24, style: .continuous)
        let x = rect.minX + min(110, rect.width * 0.3)
        p.move(to: CGPoint(x: x, y: body.maxY - 1))
        p.addQuadCurve(to: CGPoint(x: x - 18, y: rect.maxY),
                       control: CGPoint(x: x - 2, y: body.maxY + 10))
        p.addQuadCurve(to: CGPoint(x: x + 22, y: body.maxY - 1),
                       control: CGPoint(x: x + 4, y: body.maxY + 8))
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
                    let k = (x / size.width) * (1 - y / size.height)
                    let r = 1.6 * k
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
