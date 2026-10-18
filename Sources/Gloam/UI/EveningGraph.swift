// The evening in Settings as a graph: tonight's warmth and dimming over time, sunset, bedtime
// and wake marked. It is also the control for what Settings sets, and only that: drag bedtime
// or wake sideways, or a cap line (how warm, how dim it may get) up and down. Same model as the
// sliders it replaced, two caps and two clock times, so "automatic" stays one clear thing.
// (Fully editable stages and ramps were considered and left out: the stages are the evidence.)
//
// Both curves share one vertical scale, "how much", with two axes: warmth by light name on the
// left (the dial's scale, `Light.warmth`) and dimming in percent on the right (the ladder's).

import Charts
import GloamCore
import SwiftUI

struct EveningGraph: View {
    @Binding var schedule: Schedule
    let place: Coordinate
    let now: Date
    /// A limit's drag began or ended: Settings shows the night on screen while one is held.
    /// (Moving a clock time changes when, not how deep, so it previews nothing.)
    var onEditing: (Bool) -> Void = { _ in }

    private enum Handle { case bedtime, wake, warmth, dimming }
    @State private var dragging: Handle?
    @State private var hovered: Handle?
    /// The time axis is held still while a marker is dragged, or moving bedtime would move
    /// the axis under the pointer.
    @State private var heldSpan: ClosedRange<Date>?
    /// Which night is shown, held while a marker is dragged: past wake in the morning, "the
    /// evening around now" flips to last night, and the marker with it.
    @State private var heldAnchor: Date?

    private static let warm = Color.kelvin(2400), dim = Color(white: 0.82)

    private var evening: Schedule.Evening { schedule.evening(around: heldAnchor ?? now, place) }

    /// From a little before the evening starts until after wake (`Schedule.Evening.span`).
    private var span: ClosedRange<Date> { heldSpan ?? evening.span }

    private struct Point: Identifiable {
        let date: Date, warmth: Double, dimming: Double
        var id: Date { date }
    }

    private var points: [Point] {
        stride(from: span.lowerBound, through: span.upperBound, by: 5 * 60).map { d in
            let t = schedule.tint(at: d, place)
            return Point(date: d, warmth: Light.warmth(t.kelvin), dimming: Light.dimming(t.brightness))
        }
    }

    private var warmthCap: Double { Light.warmth(schedule.warmest) }
    private var dimmingCap: Double { Light.dimming(schedule.darkest) }
    /// How far each cap can go: the night stage, which is where the schedule itself stops.
    private var warmthRange: ClosedRange<Double> { 0...Light.warmth(Schedule.warmestRange.lowerBound) }
    private var dimmingRange: ClosedRange<Double> { 0...Light.dimming(Schedule.darkestRange.lowerBound) }

    var body: some View {
        let e = evening
        Chart {
            ForEach(points) { p in
                AreaMark(x: .value("Time", p.date), y: .value("Warmth", p.warmth), series: .value("Curve", "warmth"))
                    .foregroundStyle(LinearGradient(colors: [Self.warm.opacity(0.28), Self.warm.opacity(0.02)],
                                                    startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", p.date), y: .value("Warmth", p.warmth), series: .value("Curve", "warmth"))
                    .foregroundStyle(Self.warm)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", p.date), y: .value("Dimming", p.dimming), series: .value("Curve", "dimming"))
                    .foregroundStyle(Self.dim)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))  // solid: only the limits are dashed
                    .interpolationMethod(.monotone)
            }
            if let sunset = e.sunset, span.contains(sunset) {
                // Its label gives way when bedtime is close (a summer evening): two would overprint.
                let crowded = abs(sunset.timeIntervalSince(e.bedtime)) < 100 * 60
                RuleMark(x: .value("Sunset", sunset))
                    .foregroundStyle(.white.opacity(0.18))
                    .annotation(position: .top, alignment: .center) {
                        if !crowded { marker(String(localized: "Sunset"), sunset) }
                    }
            }
            RuleMark(x: .value("Bedtime", e.bedtime))
                .foregroundStyle(.white.opacity(emphasis(.bedtime)))
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .annotation(position: .top, alignment: .center) { marker(String(localized: "Bedtime"), e.bedtime) }
            RuleMark(x: .value("Wake", e.wake))
                .foregroundStyle(.white.opacity(emphasis(.wake)))
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .annotation(position: .top, alignment: .trailing) { marker(String(localized: "Wake up"), e.wake) }
            RuleMark(y: .value("Warmth limit", warmthCap))
                .foregroundStyle(Self.warm.opacity(emphasis(.warmth)))
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            RuleMark(y: .value("Dimming limit", dimmingCap))
                .foregroundStyle(Self.dim.opacity(emphasis(.dimming)))
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            // Grips: what can be dragged looks like it. Limits at their right end, times at the top.
            PointMark(x: .value("Time", span.upperBound), y: .value("Warmth limit", warmthCap))
                .foregroundStyle(Self.warm).symbolSize(dragging == .warmth ? 90 : 55)
            PointMark(x: .value("Time", span.upperBound), y: .value("Dimming limit", dimmingCap))
                .foregroundStyle(Self.dim).symbolSize(dragging == .dimming ? 90 : 55)
            PointMark(x: .value("Bedtime", e.bedtime), y: .value("Top", 1.0))
                .foregroundStyle(.white.opacity(0.85)).symbolSize(dragging == .bedtime ? 90 : 55)
            PointMark(x: .value("Wake", e.wake), y: .value("Top", 1.0))
                .foregroundStyle(.white.opacity(0.85)).symbolSize(dragging == .wake ? 90 : 55)
        }
        .chartYScale(domain: 0...1)
        .chartXScale(domain: span)
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 2)) { _ in
                AxisGridLine().foregroundStyle(.white.opacity(0.1))
                AxisValueLabel(format: .dateTime.hour()).foregroundStyle(Color.white.opacity(0.5))
            }
        }
        .chartYAxis {
            // Left: warmth, by the names the dial uses. Right: dimming, as the ladder counts it.
            AxisMarks(position: .leading, values: [0, Light.warmth(3400), Light.warmth(1900)]) { value in
                AxisGridLine().foregroundStyle(.white.opacity(0.1))
                AxisValueLabel { if let w = value.as(Double.self) { Text(Light.name(Light.kelvin(warmth: w))) } }
                    .foregroundStyle(Self.warm.opacity(0.8))
            }
            AxisMarks(position: .trailing, values: [0, 0.5, 1]) { value in
                AxisValueLabel { if let d = value.as(Double.self) { Text(Format.percent(d)) } }
                    .foregroundStyle(Self.dim.opacity(0.8))
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(drag(proxy, geo))
                    .onContinuousHover { phase in
                        guard dragging == nil else { return }
                        if case .active(let p) = phase { hovered = handle(at: p, proxy, geo) } else { hovered = nil }
                        cursor(for: hovered).set()
                    }
            }
        }
        .frame(height: 190)
        .padding(.top, 14)  // room for the markers' labels
        .help("Drag bedtime, wake up, or a dashed limit")
        // Settings closed mid-drag: nothing left held, and no preview set again on the way out.
        .onDisappear { (dragging, heldSpan, heldAnchor) = (nil, nil, nil) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tonight")
        .accessibilityValue(e.plan)
    }

    private func marker(_ title: String, _ date: Date) -> some View {
        Text("\(title) \(Format.time(date))").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            .fixedSize()
    }

    private func emphasis(_ h: Handle) -> Double { dragging == h ? 1 : hovered == h ? 0.85 : 0.6 }

    private func cursor(for h: Handle?) -> NSCursor {
        switch h {
        case .bedtime, .wake: .resizeLeftRight
        case .warmth, .dimming: .resizeUpDown
        case nil: .arrow
        }
    }

    // MARK: Dragging

    /// The nearest handle within reach of a point: a time marker sideways, a limit up or down.
    /// Nearest rather than first, so two limits close together can both be reached.
    private func handle(at p: CGPoint, _ proxy: ChartProxy, _ geo: GeometryProxy) -> Handle? {
        guard let plot = proxy.plotFrame.map({ geo[$0] }) else { return nil }
        let x = p.x - plot.minX, y = p.y - plot.minY
        let e = evening
        var near: [(Handle, Double)] = []
        for (h, date) in [(Handle.bedtime, e.bedtime), (.wake, e.wake)] {
            if let at = proxy.position(forX: date) { near.append((h, abs(at - x))) }
        }
        for (h, value) in [(Handle.warmth, warmthCap), (.dimming, dimmingCap)] {
            if let at = proxy.position(forY: value) { near.append((h, abs(at - y))) }
        }
        return near.filter { $0.1 < 10 }.min { $0.1 < $1.1 }?.0
    }

    private func endDrag() {
        guard let was = dragging else { return }
        (dragging, heldSpan, heldAnchor) = (nil, nil, nil)
        if was == .warmth || was == .dimming { onEditing(false) }
    }

    private func drag(_ proxy: ChartProxy, _ geo: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                guard let plot = proxy.plotFrame.map({ geo[$0] }) else { return }
                if dragging == nil {
                    guard let h = handle(at: g.startLocation, proxy, geo) else { return }
                    // Anchored the afternoon before this night's wake: any settable wake (04:00–12:00)
                    // or bedtime then still belongs to the same night.
                    heldAnchor = evening.wake.addingTimeInterval(-18 * 3600)
                    heldSpan = span
                    dragging = h
                    if h == .warmth || h == .dimming { onEditing(true) }
                }
                let x = g.location.x - plot.minX, y = g.location.y - plot.minY
                switch dragging {
                case .bedtime, .wake:
                    guard let date: Date = proxy.value(atX: x), let anchor = heldAnchor else { return }
                    // Clamped along this night's own timeline (`ClockTime.along`), so a far drag
                    // stays at the end it went past. The anchor is the afternoon before; wake's
                    // window starts the morning after.
                    let window = dragging == .bedtime ? Schedule.bedtimes : Schedule.wakes
                    let day = dragging == .bedtime ? anchor : anchor.addingTimeInterval(18 * 3600)
                    guard let time = ClockTime.along(window, startingOn: day, at: date) else { return }
                    if dragging == .bedtime { schedule.bedtime = time } else { schedule.wake = time }
                    // Dragged past an edge (a June evening starts after 20:00): the axis grows.
                    let marker = dragging == .bedtime ? evening.bedtime : evening.wake
                    if let held = heldSpan, !held.contains(marker) {
                        heldSpan = min(held.lowerBound, marker.addingTimeInterval(-20 * 60))...max(held.upperBound, marker.addingTimeInterval(20 * 60))
                    }
                case .warmth:
                    guard let v: Double = proxy.value(atY: y) else { return }
                    schedule.warmest = Light.kelvin(warmth: warmthRange.clamp(v))
                case .dimming:
                    guard let v: Double = proxy.value(atY: y) else { return }
                    schedule.darkest = Light.brightness(dimming: dimmingRange.clamp(v))
                case nil: break
                }
            }
            .onEnded { _ in endDrag() }
    }
}
