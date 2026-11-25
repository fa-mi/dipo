import WidgetKit
import SwiftUI

// MARK: - DiPo's complications
//
// The same three shapes as the iPhone's Lock Screen widget: a circle with
// the share of income left, a rectangle with what is left and Home's period
// line, and one line of text. They draw the snapshot the watch app keeps in
// the App Group (WatchStore), and the watch app reloads them when a new one
// arrives. Hidden on Home, hidden here.

struct WatchEntryData: TimelineEntry {
    let date: Date
    let snapshot: WatchSnapshot?
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> WatchEntryData {
        WatchEntryData(date: .now, snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (WatchEntryData) -> Void) {
        completion(WatchEntryData(date: .now, snapshot: WatchSnapshot.stored()))
    }

    /// One entry. The watch app reloads the timeline whenever the iPhone
    /// sends new figures; the hourly refresh is only a fallback.
    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchEntryData>) -> Void) {
        let entry = WatchEntryData(date: .now, snapshot: WatchSnapshot.stored())
        let next = Calendar.current.date(byAdding: .hour, value: 1, to: .now) ?? .now
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct DiPoWatchWidgetEntryView: View {
    var entry: WatchEntryData
    @Environment(\.widgetFamily) private var family

    private var amount: String {
        guard let s = entry.snapshot else { return "DiPo" }
        return s.hidden ? "••••" : s.amount
    }

    var body: some View {
        switch family {
        case .accessoryCircular:
            Gauge(value: entry.snapshot?.leftShare ?? 0) {
                Text("DiPo")
            } currentValueLabel: {
                if let s = entry.snapshot, !s.hidden {
                    Text("\(Int((s.leftShare * 100).rounded()))%")
                } else {
                    Image(systemName: "creditcard")
                }
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .widgetAccentable()
        case .accessoryInline:
            if let s = entry.snapshot {
                Text([s.labels.title + " " + amount, s.payday].compactMap { $0 }.joined(separator: " · "))
            } else {
                Text("DiPo")
            }
        default:
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.snapshot?.labels.title ?? "DiPo")
                    .font(.system(size: 12, weight: .semibold))
                    .widgetAccentable()
                Text(amount)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let s = entry.snapshot {
                    GeometryReader { g in
                        let l = min(max(s.living, 0), 1)
                        let p = min(max(s.putAway, 0), 1 - l)
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.25))
                            HStack(spacing: 0) {
                                Rectangle().fill(Color.primary).frame(width: g.size.width * l)
                                Rectangle().fill(Color.primary.opacity(0.6)).frame(width: g.size.width * p)
                            }
                            .frame(width: g.size.width, alignment: .leading)
                            .clipShape(Capsule())
                            .widgetAccentable()
                        }
                    }
                    .frame(height: 5)
                    if let payday = s.payday {
                        Text(payday)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct DiPoWatchWidget: Widget {
    /// Stable kind: never change it after shipping.
    let kind: String = "DiPoWatchWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            DiPoWatchWidgetEntryView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("DiPo")
        .description(WatchSnapshot.stored()?.labels.title ?? "DiPo")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

#Preview(as: .accessoryRectangular) {
    DiPoWatchWidget()
} timeline: {
    WatchEntryData(date: .now, snapshot: nil)
}
