import SwiftUI

// MARK: - Switches and segmented choices
//
// Two controls, shared by every setting that takes one, so the screen reads as
// one family rather than as a system switch sitting next to a hand-drawn sky.
//
// Both follow the same rule the day/night scene follows: the thing that moves
// is the thing the user chose. A selection that jumps from one segment to
// another is a redraw; a selection that travels is an answer to a tap.

/// An on/off switch, for settings that really are on or off.
///
/// It carries a glyph in the knob, because a bare capsule says only "on" while
/// these settings say something more specific — a face, a lock, a bell — and
/// the glyph is the difference between a control you read and one you decode.
struct DiPoSwitch: View {
    @Binding var isOn: Bool
    /// Optional glyphs shown inside the knob. Nil on both leaves a plain knob.
    var onIcon: String? = nil
    var offIcon: String? = nil
    var tint: Color = AppTheme.accentFill

    private let trackW: CGFloat = 52
    private let trackH: CGFloat = 32
    private var knob: CGFloat { trackH - 6 }
    private var travel: CGFloat { (trackW - knob - 6) / 2 }

    var body: some View {
        ZStack {
            Capsule()
                .fill(isOn ? tint : AppTheme.textSecondary.opacity(0.28))
            Circle()
                .fill(.white)
                .frame(width: knob, height: knob)
                .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                .overlay {
                    if let icon = isOn ? onIcon : offIcon {
                        Image(systemName: icon)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(isOn ? tint : AppTheme.textSecondary)
                    }
                }
                .offset(x: isOn ? travel : -travel)
        }
        .frame(width: trackW, height: trackH)
        .animation(.spring(response: 0.32, dampingFraction: 0.72), value: isOn)
        .contentShape(Capsule())
        .onTapGesture {
            HapticManager.shared.tap()
            isOn.toggle()
        }
        // VoiceOver hears a real switch, with the real binding behind it, rather
        // than a picture of one.
        .accessibilityRepresentation { Toggle("", isOn: $isOn) }
    }
}

/// A row of choices where the selection slides between them.
///
/// The settings that take two or three options — app language, voice language —
/// were rows of flat segments whose accent fill appeared under whichever one was
/// tapped. Nothing travelled, so nothing connected the tap to the result. Here
/// one pill moves, and it is the same pill.
struct SlidingSegments<Option: Hashable, Label: View>: View {
    let options: [Option]
    let selection: Option
    let onSelect: (Option) -> Void
    @ViewBuilder var label: (Option, Bool) -> Label

    @Namespace private var pill

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                let on = option == selection
                Button {
                    guard !on else { return }
                    HapticManager.shared.tap()
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                        onSelect(option)
                    }
                } label: {
                    label(option, on)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: AppRadius.sm)
                                    .fill(AppTheme.accentFill)
                                    .matchedGeometryEffect(id: "segment", in: pill)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(ScaleButtonStyle())
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(4)
        .background(AppTheme.cardMid, in: RoundedRectangle(cornerRadius: AppRadius.md))
    }
}
