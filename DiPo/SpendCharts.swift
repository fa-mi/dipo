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
}

struct SpendDonut: View {
    let slices: [DonutSlice]
    let total: Double
    /// Passed in rather than formatted here: the currency rules live with the
    /// screen, and a second implementation of money formatting is a second
    /// answer to the same question.
    let format: (Double) -> String
    var centerCaption: String

    /// The thickest a slice gets. Every arc grows INWARD from this, so the
    /// hole stays put and the outer edge is what varies.
    var ring: CGFloat = 30
    @State private var selectedID: String? = nil

    /// Slices below this are drawn but not labelled — a "2%" printed across a
    /// sliver is unreadable and pushes into its neighbours.
    private let labelFloor = 0.07
    /// The gap between slices, as a fraction of the circle. Wide enough to read
    /// as air between separate things rather than as a hairline.
    private let gap = 0.016
    /// The thinnest a slice is drawn, as a share of `ring`.
    private let floorWidth = 0.55

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

    /// Thickness follows the share, so the ring says which is biggest twice —
    /// by how far it travels and by how heavy it is. A flat ring of even width
    /// leaves the whole job to arc length, which is the hardest thing on a
    /// circle to compare by eye.
    private func width(_ arc: Arc) -> CGFloat {
        let t = largest > 0 ? arc.fraction / largest : 1
        return ring * CGFloat(floorWidth + (1 - floorWidth) * t)
    }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                ForEach(arcs) { arc in
                    let on = arc.id == selectedID
                    let w = width(arc) + (on ? 6 : 0)
                    // Inset so each arc keeps the same INNER edge whatever its
                    // width: stroking a circle grows both ways, which would eat
                    // into the hole and leave the middle figure crowded.
                    Circle()
                        .inset(by: ring - w / 2)
                        .trim(from: min(arc.start + gap / 2, arc.end - 0.002),
                              to: max(arc.end - gap / 2, arc.start + 0.002))
                        .stroke(arc.slice.color,
                                style: StrokeStyle(lineWidth: w, lineCap: .round))
                        .opacity(selectedID == nil || on ? 1 : 0.4)
                }
                .rotationEffect(.degrees(-90))

                ForEach(arcs.filter { $0.fraction >= labelFloor }) { arc in
                    let mid = Angle(degrees: ((arc.start + arc.end) / 2) * 360 - 90)
                    // The middle of THIS arc's band, which moves with its width.
                    let r = side / 2 - ring + width(arc) / 2
                    Text("\(Int((arc.fraction * 100).rounded()))%")
                        .font(.system(.caption2, weight: .bold))
                        .foregroundStyle(.white)
                        .offset(x: cos(mid.radians) * r, y: sin(mid.radians) * r)
                }

                center
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Circle())
            // A tap anywhere on the ring picks the slice under the finger, and
            // a tap on the same slice puts it back — the centre has to be able
            // to return to the total, or the first tap is a one-way door.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { v in select(at: v.location, in: CGSize(width: side, height: side)) }
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
                .font(.system(.subheadline, weight: .bold))
                .foregroundStyle(AppTheme.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.6)
            if let s = selected {
                Text("\(Int((s.fraction * 100).rounded()))%")
                    .font(.system(.caption2, weight: .semibold))
                    .foregroundStyle(s.slice.color)
            }
        }
        .padding(.horizontal, ring + 6)
    }

    private func select(at point: CGPoint, in size: CGSize) {
        let dx = point.x - size.width / 2
        let dy = point.y - size.height / 2
        let radius = sqrt(dx * dx + dy * dy)
        // Ignore the hole: a tap in the middle is a tap on the figure, not on a
        // slice, and guessing one there would flip the centre at random.
        guard radius > size.width / 2 - ring - 8, radius < size.width / 2 + 8 else { return }
        var deg = atan2(dy, dx) * 180 / .pi + 90
        if deg < 0 { deg += 360 }
        let f = deg / 360
        guard let hit = arcs.first(where: { f >= $0.start && f < $0.end }) else { return }
        HapticManager.shared.select()
        selectedID = (selectedID == hit.id) ? nil : hit.id
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
