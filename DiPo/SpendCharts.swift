import SwiftUI

// MARK: - Donut
//
// The category breakdown was a ranked list of bars. A list answers "which
// category is biggest" well and "how is the month divided" badly — that second
// question is about proportion, and proportion is what a ring shows at a
// glance.
//
// The ring does not replace the list; it sits above it. The list keeps the
// figures, because a ring cannot be read to the rupiah and pretending otherwise
// is how a chart starts lying.

struct DonutSlice: Identifiable {
    let id: String
    let label: String
    let amount: Double
    let color: Color
    /// What the share printed inside this slice is drawn in. Passed rather than
    /// derived: only the caller knows how pale it made the fill, and white on a
    /// pale slice is unreadable.
    var labelColor: Color = .white
}

struct SpendDonut: View {
    let slices: [DonutSlice]
    let total: Double
    /// Passed in rather than formatted here: the currency rules live with the
    /// screen, and a second implementation of money formatting is a second
    /// answer to the same question.
    let format: (Double) -> String
    var centerCaption: String

    @State private var selectedID: String? = nil

    // Every proportion below was read off a rendered comparison with the
    // reference, not reasoned about. A slice is TWO things: a thin arc on the
    // rim, and a pale wedge sitting inside it with a gap of card between them.
    // The wedge's DEPTH carries the share — the big ones reach toward the
    // middle and the small ones barely leave the rim — which is why the hole is
    // not a circle. Three earlier attempts drew one band and varied its weight;
    // that is a different chart.
    private let arcWeight: CGFloat = 0.033   // × side
    private let rimInset: CGFloat = 0.007    // × side, breathing room outside the arc
    private let radialGap: CGFloat = 0.020   // × side, card showing between arc and wedge
    private let baseDepth: CGFloat = 0.127   // × side, the shallowest wedge
    private let spanDepth: CGFloat = 0.093   // × side, added at the largest share
    private let roundness: CGFloat = 0.020   // × side, the wedge's corner radius
    private let gapDeg = 8.0                 // between slices
    private let wedgeInsetDeg = 1.8          // wedge sits inside its own arc

    /// Slices below this are drawn but not labelled — a "2%" printed across a
    /// sliver is unreadable and pushes into its neighbours.
    private let labelFloor = 0.07

    private struct Arc: Identifiable {
        let slice: DonutSlice
        let start: Double
        let end: Double
        var id: String { slice.id }
        var fraction: Double { end - start }
    }

    private var arcs: [Arc] {
        guard total > 0 else { return [] }
        var out: [Arc] = []
        var acc = 0.0
        for s in slices where s.amount > 0 {
            let f = s.amount / total
            out.append(Arc(slice: s, start: acc, end: acc + f))
            acc += f
        }
        return out
    }

    private var selected: Arc? { arcs.first { $0.id == selectedID } }
    private var largest: Double { arcs.map(\.fraction).max() ?? 1 }

    private func depth(_ arc: Arc, side: CGFloat) -> CGFloat {
        let t = largest > 0 ? arc.fraction / largest : 1
        return side * (baseDepth + spanDepth * CGFloat(t))
    }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let arcW = side * arcWeight
            let rOut = side / 2 - arcW / 2 - side * rimInset
            let wedgeOut = rOut - arcW / 2 - side * radialGap

            ZStack {
                ForEach(arcs) { arc in
                    let on = selectedID == nil || arc.id == selectedID
                    let a0 = arc.start * 360 + gapDeg / 2
                    let a1 = max(arc.end * 360 - gapDeg / 2, arc.start * 360 + gapDeg / 2 + 0.5)
                    let wedgeIn = max(wedgeOut - depth(arc, side: side), side * 0.14)
                    let wedge = WedgeSegment(inner: wedgeIn, outer: wedgeOut,
                                             from: a0 + wedgeInsetDeg, to: max(a1 - wedgeInsetDeg,
                                                                               a0 + wedgeInsetDeg + 0.5))
                    // The rim.
                    ArcSegment(radius: rOut, from: a0, to: a1)
                        .stroke(arc.slice.color,
                                style: StrokeStyle(lineWidth: arcW, lineCap: .round))
                        .opacity(on ? 1 : 0.35)
                    // The wedge, filled and then stroked in its own colour:
                    // that stroke is what rounds the four corners, which a
                    // plain annular sector does not have.
                    wedge
                        .fill(arc.slice.color.opacity(0.42))
                        .opacity(on ? 1 : 0.35)
                    wedge
                        .stroke(arc.slice.color.opacity(0.42),
                                style: StrokeStyle(lineWidth: side * roundness,
                                                   lineCap: .round, lineJoin: .round))
                        .opacity(on ? 1 : 0.35)
                }

                ForEach(arcs.filter { $0.fraction >= labelFloor }) { arc in
                    let mid = Angle(degrees: ((arc.start + arc.end) / 2) * 360 - 90)
                    let wedgeIn = max(wedgeOut - depth(arc, side: side), side * 0.14)
                    let r = (wedgeIn + wedgeOut) / 2
                    Text("\(Int((arc.fraction * 100).rounded()))%")
                        .font(.system(.caption2, weight: .bold))
                        .foregroundStyle(arc.slice.labelColor)
                        .offset(x: cos(mid.radians) * r, y: sin(mid.radians) * r)
                }

                center
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Circle())
            // A tap anywhere on a slice picks it, and a tap on the same slice
            // puts it back — the centre has to be able to return to the total,
            // or the first tap is a one-way door.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { v in select(at: v.location, side: side, outer: rOut + arcW) }
            )
            .animation(.spring(response: 0.32, dampingFraction: 0.8), value: selectedID)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private var center: some View {
        VStack(spacing: 2) {
            Text(selected?.slice.label ?? centerCaption)
                .font(.system(.caption2))
                .foregroundStyle(AppTheme.textSecondary)
                .lineLimit(1)
            Text(format(selected?.slice.amount ?? total))
                .font(.system(.footnote, weight: .bold))
                .foregroundStyle(AppTheme.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.55)
            if let s = selected {
                Text("\(Int((s.fraction * 100).rounded()))%")
                    .font(.system(.caption2, weight: .semibold))
                    .foregroundStyle(s.slice.color)
            }
        }
        // The hole is small and uneven by design, so the figure inside it has
        // to stay narrow.
        .frame(maxWidth: 96)
    }

    private func select(at point: CGPoint, side: CGFloat, outer: CGFloat) {
        let dx = point.x - side / 2
        let dy = point.y - side / 2
        let radius = sqrt(dx * dx + dy * dy)
        // Ignore the hole: a tap in the middle is a tap on the figure, not on a
        // slice, and guessing one there would flip the centre at random.
        guard radius > side * 0.14, radius < outer else { return }
        var deg = atan2(dy, dx) * 180 / .pi + 90
        if deg < 0 { deg += 360 }
        let f = deg / 360
        guard let hit = arcs.first(where: { f >= $0.start && f < $0.end }) else { return }
        HapticManager.shared.select()
        selectedID = (selectedID == hit.id) ? nil : hit.id
    }
}

/// One band of the rim. Degrees, clockwise, 0 at twelve o'clock — the way the
/// chart is read rather than the way trigonometry numbers it.
private struct ArcSegment: Shape {
    var radius: CGFloat
    var from: Double
    var to: Double

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: radius,
                 startAngle: .degrees(from - 90), endAngle: .degrees(to - 90), clockwise: false)
        return p
    }
}

/// The filled part of a slice: an annular sector, rounded by being stroked in
/// its own colour rather than by any corner maths.
private struct WedgeSegment: Shape {
    var inner: CGFloat
    var outer: CGFloat
    var from: Double
    var to: Double

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var p = Path()
        p.addArc(center: c, radius: outer,
                 startAngle: .degrees(from - 90), endAngle: .degrees(to - 90), clockwise: false)
        p.addArc(center: c, radius: inner,
                 startAngle: .degrees(to - 90), endAngle: .degrees(from - 90), clockwise: true)
        p.closeSubpath()
        return p
    }
}

// MARK: - Line

/// Spending across a period, as a line with the ground filled in under it.
///
/// Bars are right for a handful of finished periods; days inside one period are
/// a continuous story, and a line tells it with the shape of the week rather
/// than seven separate heights. Dragging along it names the day and the figure,
/// because a line without a readable value is decoration.
struct SpendLinePoint: Identifiable {
    let id: Int
    let label: String
    let value: Double
    /// Days that have not happened. They hold the x-axis open but the line
    /// stops before them — drawing them at zero would report a quiet day that
    /// has not had its chance yet.
    var isFuture: Bool = false
}

struct SpendLineChart: View {
    let points: [SpendLinePoint]
    var tint: Color = AppTheme.blue
    let format: (Double) -> String

    @State private var selected: Int? = nil

    private var drawn: [SpendLinePoint] { points.filter { !$0.isFuture } }
    private var peak: Double { max(points.map(\.value).max() ?? 0, 1) }

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                let step = points.count > 1 ? w / CGFloat(points.count - 1) : w

                ZStack(alignment: .topLeading) {
                    if drawn.count >= 2 {
                        // The ground under the line, so the eye reads volume
                        // and not just direction.
                        Path { p in
                            p.move(to: CGPoint(x: xPos(drawn[0].id, step: step), y: h))
                            for pt in drawn { p.addLine(to: CGPoint(x: xPos(pt.id, step: step), y: yPos(pt.value, height: h))) }
                            p.addLine(to: CGPoint(x: xPos(drawn[drawn.count - 1].id, step: step), y: h))
                            p.closeSubpath()
                        }
                        .fill(LinearGradient(colors: [tint.opacity(0.28), tint.opacity(0.02)],
                                             startPoint: .top, endPoint: .bottom))

                        Path { p in
                            p.move(to: CGPoint(x: xPos(drawn[0].id, step: step), y: yPos(drawn[0].value, height: h)))
                            for pt in drawn.dropFirst() { p.addLine(to: CGPoint(x: xPos(pt.id, step: step), y: yPos(pt.value, height: h))) }
                        }
                        .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    }

                    if let last = drawn.last {
                        dot.position(x: xPos(last.id, step: step), y: yPos(last.value, height: h))
                    }

                    if let i = selected, let pt = points.first(where: { $0.id == i }), !pt.isFuture {
                        Rectangle()
                            .fill(tint.opacity(0.35))
                            .frame(width: 1)
                            .frame(maxHeight: .infinity)
                            .position(x: xPos(i, step: step), y: h / 2)
                        dot.position(x: xPos(i, step: step), y: yPos(pt.value, height: h))
                        bubble(pt)
                            .position(x: min(max(xPos(i, step: step), 52), w - 52), y: max(yPos(pt.value, height: h) - 30, 16))
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            let i = Int((v.location.x / step).rounded())
                            let clamped = min(max(i, 0), points.count - 1)
                            if clamped != selected, !(points.first { $0.id == clamped }?.isFuture ?? true) {
                                HapticManager.shared.select()
                                selected = clamped
                            }
                        }
                        .onEnded { _ in selected = nil }
                )
            }
            .frame(height: 132)

            HStack(spacing: 4) {
                ForEach(points) { pt in
                    Text(pt.label)
                        .font(.system(size: 10, weight: selected == pt.id ? .bold : .medium))
                        .foregroundStyle(selected == pt.id ? AppTheme.textPrimary
                                                           : AppTheme.textSecondary.opacity(0.8))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func xPos(_ i: Int, step: CGFloat) -> CGFloat { CGFloat(i) * step }

    private func yPos(_ v: Double, height: CGFloat) -> CGFloat {
        height - CGFloat(v / peak) * (height - 10) - 5
    }

    private var dot: some View {
        Circle()
            .fill(AppTheme.cardDark)
            .frame(width: 11, height: 11)
            .overlay(Circle().stroke(tint, lineWidth: 2.5))
    }

    private func bubble(_ pt: SpendLinePoint) -> some View {
        VStack(spacing: 1) {
            Text(format(pt.value))
                .font(.system(.caption2, weight: .bold))
                .foregroundStyle(AppTheme.onVividFill)
            Text(pt.label)
                .font(.system(size: 9))
                .foregroundStyle(AppTheme.onVividFill.opacity(0.75))
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(AppTheme.textPrimary, in: RoundedRectangle(cornerRadius: AppRadius.sm))
        .fixedSize()
    }
}
