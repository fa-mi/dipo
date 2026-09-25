import SwiftUI

// MARK: - Ticket
//
// A receipt is the object a transaction already is: one purchase, one moment,
// one piece of paper. The detail screen used to be the app's standard stack of
// cards, which is the right shape for a settings page and a slightly anonymous
// one for "here is the coffee you bought on Tuesday".
//
// The paper is CUT, not painted over. The first version laid backdrop-coloured
// circles on top of the card to fake the notches, which failed in two ways on a
// real screen: the card's shadow fell on those circles too, so they read as
// beads stuck to the sides rather than bites taken out, and along the bottom the
// circles could not touch each other, so the white card showed between them as a
// row of bumps. A shape with real holes has neither problem, needs no colour to
// match anything, and works over any background.

struct TicketCard<Stub: View, Particulars: View>: View {
    var surface: Color = AppTheme.cardDark
    @ViewBuilder var stub: () -> Stub
    @ViewBuilder var particulars: () -> Particulars

    private let notch: CGFloat = 11
    private let corner: CGFloat = 24
    private let scallop: CGFloat = 7
    private let space = "ticket"

    /// Where the fold sits, measured rather than assumed: the stub above it
    /// changes height with the amount, the name and whether there is an
    /// exchange rate to print.
    @State private var foldY: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            stub()
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.top, 22)
                .padding(.bottom, 16)

            fold

            particulars()
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 20 + scallop)
        }
        .coordinateSpace(.named(space))
        .background { paper }
    }

    /// The paper, with the notches and the torn edge ERASED out of it.
    ///
    /// Two earlier attempts got this wrong in the same place. Painting
    /// backdrop-coloured circles on top of the card made the card's shadow fall
    /// on them, so they read as beads stuck to the sides. Then an even-odd fill
    /// went wrong the other way: even-odd fills whatever is covered an ODD
    /// number of times, and the half of each circle that hangs OUTSIDE the card
    /// is covered exactly once — so it filled, and the bites came out as bumps.
    ///
    /// `destinationOut` has neither failure mode. The circles are not drawn at
    /// all; they remove what is already there, and removing nothing outside the
    /// card is exactly what should happen. The shadow is taken after the holes
    /// are cut, so it follows the notched outline.
    private var paper: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack(alignment: .topLeading) {
                UnevenRoundedRectangle(topLeadingRadius: corner, bottomLeadingRadius: 0,
                                       bottomTrailingRadius: 0, topTrailingRadius: corner)
                    .fill(surface)
                    .frame(width: w, height: h)

                Group {
                    // The fold's two bites, centred ON each edge.
                    Circle().frame(width: notch * 2, height: notch * 2)
                        .position(x: 0, y: foldY)
                    Circle().frame(width: notch * 2, height: notch * 2)
                        .position(x: w, y: foldY)
                    // The torn bottom. They tile edge to edge; a gap between two
                    // bites is a bump, which is what the first version produced.
                    ForEach(0..<max(Int((w / (scallop * 2)).rounded(.up)), 1), id: \.self) { i in
                        Circle().frame(width: scallop * 2, height: scallop * 2)
                            .position(x: CGFloat(i) * scallop * 2 + scallop, y: h)
                    }
                }
                .blendMode(.destinationOut)
            }
            .compositingGroup()
            .shadow(color: .black.opacity(0.16), radius: 12, y: 5)
        }
    }

    /// The perforation. Only the dashed line is drawn — the bites at either end
    /// are cut out of the paper itself.
    private var fold: some View {
        Rectangle()
            .stroke(style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
            .foregroundStyle(AppTheme.textSecondary.opacity(0.35))
            .frame(height: 1)
            .padding(.horizontal, notch + 10)
            .frame(height: notch * 2)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.frame(in: .named(space)).midY
            } action: { foldY = $0 }
    }
}

// MARK: - Barcode

/// Bars drawn from the transaction's own id, so the same purchase always
/// carries the same code and two of them never look alike.
///
/// It encodes nothing a scanner could read, and it is not pretending to: the
/// id is printed in full beneath it, which is the part anyone would ever need
/// to quote back.
struct TicketBarcode: View {
    let id: UUID
    var bars: Int = 46

    private var bytes: [UInt8] {
        withUnsafeBytes(of: id.uuid) { Array($0) }
    }

    var body: some View {
        let b = bytes
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<bars, id: \.self) { i in
                let v = b[i % b.count] &+ UInt8(i % 7)
                Rectangle()
                    .fill(AppTheme.textPrimary.opacity(v % 4 == 0 ? 0.25 : 0.8))
                    .frame(width: v % 5 == 0 ? 3 : (v % 3 == 0 ? 2 : 1))
            }
        }
        .frame(height: 36)
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }
}
