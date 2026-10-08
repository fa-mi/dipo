import SwiftUI
import AVFoundation

// MARK: - DiPo Quest: look, feel and sound
//
// The game's own small design system, after Duolingo's: rounded heavy type,
// "chunky" buttons standing on a darker lip that they sink into when pressed,
// one task per screen, a haptic and a short sound for every outcome. Colours
// are the app's own tokens; the lip is the same colour with black laid over
// it at the call site, so no new colour enters the palette.

extension Font {
    /// SF Pro Rounded — the system's free answer to Duolingo's Feather.
    static func quest(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

/// A button that stands on a lip and sinks into it when pressed.
struct ChunkyButtonStyle: ButtonStyle {
    var fill: Color = AppTheme.accent
    var ink: Color = AppTheme.onVividFill
    var stroke: Color = .clear
    /// The lip under the face. Nil: the fill, darkened.
    var lip: Color? = nil
    var radius: CGFloat = 16
    var depth: CGFloat = 4

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let pressed = configuration.isPressed
        return configuration.label
            .foregroundStyle(ink)
            .background(shape.fill(fill))
            .overlay(shape.stroke(stroke, lineWidth: 2))
            .offset(y: pressed ? depth : 0)
            .background {
                ZStack {
                    shape.fill(lip ?? fill)
                    if lip == nil { shape.fill(Color.black.opacity(0.25)) }
                }
                .offset(y: depth)
            }
            .padding(.bottom, depth)
            .animation(.spring(response: 0.16, dampingFraction: 0.7), value: pressed)
    }
}

/// The wide call-to-action at the bottom of a game screen.
struct QuestCTA: View {
    let title: String
    var fill: Color = AppTheme.accent
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.quest(17, .heavy))
                .tracking(0.6)
                .frame(maxWidth: .infinity, minHeight: 52)
        }
        .buttonStyle(ChunkyButtonStyle(fill: enabled ? fill : AppTheme.cardMid,
                                       ink: enabled ? AppTheme.onVividFill : AppTheme.textSecondary,
                                       lip: enabled ? nil : AppTheme.cardMid))
        .disabled(!enabled)
    }
}

// MARK: - Sound

/// Short synthesized cues — no audio files. Ambient, so the ring/silent
/// switch silences them and other audio keeps playing.
@MainActor
final class QuestSound {
    static let shared = QuestSound()
    enum Cue { case tap, correct, wrong, complete, chest }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)
    private var ready = false

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "quest_sound_on") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "quest_sound_on") }
    }

    func play(_ cue: Cue) {
        guard enabled, let format else { return }
        if !ready {
            let session = AVAudioSession.sharedInstance()
            if session.category != .playback {
                try? session.setCategory(.ambient, options: [.mixWithOthers])
            }
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            ready = true
        }
        if !engine.isRunning { try? engine.start() }
        guard engine.isRunning, let buffer = Self.buffer(for: cue, format: format) else { return }
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        if !player.isPlaying { player.play() }
    }

    /// (frequency Hz, seconds) per note.
    private static func notes(_ cue: Cue) -> [(Double, Double)] {
        switch cue {
        case .tap:      return [(1_320, 0.035)]
        case .correct:  return [(659.3, 0.09), (987.8, 0.18)]
        case .wrong:    return [(220, 0.12), (174.6, 0.22)]
        case .complete: return [(523.3, 0.1), (659.3, 0.1), (784, 0.1), (1_046.5, 0.28)]
        case .chest:    return [(784, 0.08), (1_046.5, 0.08), (1_318.5, 0.24)]
        }
    }

    private static func buffer(for cue: Cue, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let rate = format.sampleRate
        let notes = notes(cue)
        let frames = AVAudioFrameCount(notes.reduce(0) { $0 + $1.1 } * rate)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let out = buf.floatChannelData?[0] else { return nil }
        buf.frameLength = frames
        var i = 0
        let soft = cue == .wrong
        for (freq, secs) in notes {
            let n = Int(secs * rate)
            for k in 0..<n where i < Int(frames) {
                let t = Double(k) / rate
                let attack = min(1, t / 0.005)
                let env = attack * exp(-t * (soft ? 9 : 14))
                var v = sin(2 * .pi * freq * t)
                // A touch of the octave makes it ring; the wrong cue stays dull.
                if !soft { v += 0.3 * sin(4 * .pi * freq * t) }
                out[i] = Float(v * env * (cue == .tap ? 0.12 : 0.22))
                i += 1
            }
        }
        return buf
    }
}

// MARK: - Haptics and sound together

@MainActor
enum QuestFeedback {
    static func select() { HapticManager.shared.select(); QuestSound.shared.play(.tap) }
    static func correct() { HapticManager.shared.success(); QuestSound.shared.play(.correct) }
    static func wrong() { HapticManager.shared.error(); QuestSound.shared.play(.wrong) }
    static func complete() { HapticManager.shared.success(); QuestSound.shared.play(.complete) }
    static func chest() { HapticManager.shared.rigidImpact(); QuestSound.shared.play(.chest) }
}

extension QuestQuestion.Kind {
    var icon: String {
        switch self {
        case .cheaper:  return "scalemass.fill"
        case .change:   return "banknote.fill"
        case .total:    return "cart.fill"
        case .needWant: return "hand.raised.fill"
        case .saving:   return "dollarsign.circle.fill"
        case .days:     return "calendar"
        case .interest: return "percent"
        case .loan:     return "creditcard.fill"
        case .scam:     return "exclamationmark.shield.fill"
        case .profit:   return "chart.line.uptrend.xyaxis"
        case .price:    return "tag.fill"
        case .fact:     return "checkmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .cheaper, .total, .change: return AppTheme.blue
        case .needWant, .fact:          return AppTheme.purple
        case .saving, .days:            return AppTheme.accent
        case .interest, .loan:          return AppTheme.orange
        case .scam:                     return AppTheme.red
        case .profit, .price:           return AppTheme.teal
        }
    }
}

extension QuestUnit {
    /// Each unit in one of the app's own hues, in turn.
    var tint: Color {
        [AppTheme.accent, AppTheme.blue, AppTheme.purple, AppTheme.orange, AppTheme.red, AppTheme.teal][(id - 1) % 6]
    }
}
