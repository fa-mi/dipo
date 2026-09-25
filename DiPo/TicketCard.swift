import SwiftUI

// MARK: - Ticket
//
// A receipt is the object a transaction already is: one purchase, one moment,
// one piece of paper. The detail screen used to be the app's standard stack of
// cards, which is the right shape for a settings page and a slightly anonymous
// one for "here is the coffee you bought on Tuesday".
//
// The paper is drawn rather than illustrated: a stub, a torn edge with a notch
// bitten out of each side, then the particulars and a barcode. The notches and
// the scalloped bottom are backdrop-coloured shapes laid over the card, which
// is the cheap and sturdy way to do this — it does mean the `backdrop` colour
// has to be whatever is actually behind the ticket, so a ticket over anything
// but a flat background needs a different approach.

struct TicketCard<Stub: View, Particulars: View>: View {
    var surface: Color = AppTheme.cardDark
    var backdrop: Color = AppTheme.bg
    @ViewBuilder var stub: () -> Stub
    @ViewBuilder var particulars: () -> Particulars

    private let notch: CGFloat = 11
    private let corner: CGFloat = 24
    private let scallop: CGFloat = 7

    var body: some View {
        VStack(spacing: 0) {
            stub()
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.top, 22)
                .padding(.bottom, 16)

            tear

            particulars()
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 20)
        }
        .background(
            // Flat along the bottom, because the scallops below eat that edge —
            // a rounded corner under a row of bites reads as a mistake.
            UnevenRoundedRectangle(topLeadingRadius: corner, bottomLeadingRadius: 0,
                                   bottomTrailingRadius: 0, topTrailingRadius: corner)
                .fill(surface)
        )
        .overlay(alignment: .bottom) { scallops }
        .shadow(color: .black.opacity(0.16), radius: 12, y: 5)
    }

    /// The fold: a dashed line with a half-circle taken out of each edge.
    private var tear: some View {
        ZStack {
            Rectangle()
                .fill(.clear)
                .frame(height: 1)
                .overlay(
                    Rectangle()
                        .stroke(style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
                        .foregroundStyle(AppTheme.textSecondary.opacity(0.35))
                        .frame(height: 1)
                )
                .padding(.horizontal, notch + 8)

            HStack {
                notchCircle.offset(x: -notch)
                Spacer(minLength: 0)
                notchCircle.offset(x: notch)
            }
        }
        .frame(height: notch * 2)
    }

    private var notchCircle: some View {
        Circle()
            .fill(backdrop)
            .frame(width: notch * 2, height: notch * 2)
    }

    /// The torn-off bottom edge.
    private var scallops: some View {
        HStack(spacing: 0) {
            ForEach(0..<22, id: \.self) { _ in
                Circle()
                    .fill(backdrop)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(1, contentMode: .fit)
            }
        }
        .frame(height: scallop * 2)
        .offset(y: scallop)
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
