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

/// The outline: rounded top, a notch bitten out of each side at the fold, and a
/// torn bottom edge. Filled with the even-odd rule, so every circle added here
/// removes what it overlaps instead of adding to it.
struct TicketShape: Shape {
    /// Distance from the top of the card to the middle of the fold.
    var notchY: CGFloat
    var notchR: CGFloat = 11
    var corner: CGFloat = 24
    var scallopR: CGFloat = 7

    // Lets the fold animate into place rather than jumping when the content
    // above it changes height.
    var animatableData: CGFloat {
        get { notchY }
        set { notchY = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addRoundedRect(in: rect, cornerSize: CGSize(width: corner, height: corner))

        // The two side notches. Centred ON the edge, so exactly half of each
        // circle overlaps the card and is removed.
        if notchY > 0 {
            p.addEllipse(in: CGRect(x: rect.minX - notchR, y: rect.minY + notchY - notchR,
                                    width: notchR * 2, height: notchR * 2))
            p.addEllipse(in: CGRect(x: rect.maxX - notchR, y: rect.minY + notchY - notchR,
                                    width: notchR * 2, height: notchR * 2))
        }

        // The torn bottom. They touch, because a gap between two bites is a
        // bump, which is exactly what the painted version produced.
        var x = rect.minX + scallopR
        while x < rect.maxX + scallopR {
            p.addEllipse(in: CGRect(x: x - scallopR, y: rect.maxY - scallopR,
                                    width: scallopR * 2, height: scallopR * 2))
            x += scallopR * 2
        }
        return p
    }
}

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
        .background {
            TicketShape(notchY: foldY, notchR: notch, corner: corner, scallopR: scallop)
                .fill(surface, style: FillStyle(eoFill: true))
                // On the shape, not on the whole card: a shadow cast by the
                // overlay circles is what made the first version look like
                // beads glued to the sides.
                .shadow(color: .black.opacity(0.16), radius: 12, y: 5)
        }
    }

    /// The perforation. Only the dashed line is drawn — the bites at either end
    /// belong to the shape now.
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
