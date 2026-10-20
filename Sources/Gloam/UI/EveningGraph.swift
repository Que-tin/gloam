// The evening in Settings as a graph: tonight's warmth and dimming over time, sunset, bedtime
// and wake marked. It is also the control for what Settings sets, and only that: drag bedtime
// or wake sideways, or a cap line (how warm, how dim it may get) up and down. Two caps and two
// clock times, so "automatic" stays one clear thing.
// (Fully editable stages and ramps were considered and left out: the stages are the evidence.)
//
// Both curves share one vertical scale, "how much", with two axes: warmth in Kelvin on the left
// and dimming in percent on the right, both on the schedule's fixed scales (`Light.warmth`,
// `Light.dimming`), the popover's dial and ladder too.

import Charts
import GloamCore
import SwiftUI

struct EveningGraph: View {
    @Binding var schedule: Schedule
    let place: Coordinate
    /// The wake that ends the evening to show (`AppModel.eveningWake`): changes once a day, so
    /// the chart isn't redrawn on every clock tick the way passing "now" did.
    let wake: Date

    private enum Handle { case bedtime, wake, warmth, dimming }
    @State private var dragging: Handle?
    @State private var hovered: Handle?
    /// The time axis is held still while a marker is dragged, or moving bedtime would move
    /// the axis under the pointer.
    @State private var heldSpan: ClosedRange<Date>?
    /// Which night is shown, held while a marker is dragged: past wake in the morning, "the
    /// evening around now" flips to last night, and the marker with it.
    @State private var heldAnchor: Date?
    /// The keyboard's marker: focus the graph, ←/→ move it, ↑/↓ switch bedtime and wake (the
    /// graph is their only control). The ring shows only for keyboard focus.
    @State private var keyMarker = Handle.bedtime
    /// The plot's width, for telling whether two markers' labels fit side by side.
    @State private var plotWidth: CGFloat = 280
    @State private var ring = false

    /// Settings' legend keys use them too: each dot matches its curve.
    static let warm = Color.kelvin(2400), dim = Color(white: 0.82)
    private static let axisWidth: CGFloat = 46

    private var evening: Schedule.Evening { schedule.evening(around: heldAnchor ?? wake.addingTimeInterval(-3600), place) }

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
    /// How far each limit can go: the whole scale (ember, 30 %), past the recommended night.
    private var warmthRange: ClosedRange<Double> { 0...Light.warmth(Schedule.warmestRange.lowerBound) }
    private var dimmingRange: ClosedRange<Double> { 0...Light.dimming(Schedule.darkestRange.lowerBound) }
    /// Where the recommended night sits on each scale: a drag back within a step snaps onto it.
    private static let recommended = (warmth: Light.warmth(Schedule.recommendedNight.kelvin),
                                      dimming: Light.dimming(Schedule.recommendedNight.brightness))

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
            let bedLabel = String(localized: "Bedtime \(Format.time(e.bedtime))")
            if let sunset = e.sunset, span.contains(sunset) {
                // Its label gives way when bedtime's is too close to fit beside it (a summer evening,
                // or the longer labels of a 12-hour clock): two would overprint.
                let sunsetLabel = String(localized: "Sunset \(Format.time(sunset))")
                let apart = abs(sunset.timeIntervalSince(e.bedtime)) / span.upperBound.timeIntervalSince(span.lowerBound) * plotWidth
                // Centred if it fits, else ending at its line (above the axis labels, which are free there).
                let centred = apart >= (Self.width(of: sunsetLabel) + Self.width(of: bedLabel)) / 2 + 8
                let crowded = apart < Self.width(of: bedLabel) / 2 + 8
                RuleMark(x: .value("Sunset", sunset))
                    .foregroundStyle(.white.opacity(0.18))
                    .annotation(position: .top, alignment: centred ? .center : .trailing,
                                overflowResolution: .init(x: .disabled, y: .disabled)) {
                        if !crowded { marker(sunsetLabel) }
                    }
            }
            RuleMark(x: .value("Bedtime", e.bedtime))
                .foregroundStyle(.white.opacity(emphasis(.bedtime)))
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .annotation(position: .top, alignment: .center) { marker(bedLabel) }
            RuleMark(x: .value("Wake", e.wake))
                .foregroundStyle(.white.opacity(emphasis(.wake)))
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .annotation(position: .top, alignment: .trailing) { marker(String(localized: "Wake-up \(Format.time(e.wake))")) }
            RuleMark(y: .value("Warmth limit", warmthCap))
                .foregroundStyle(Self.warm.opacity(emphasis(.warmth)))
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            RuleMark(y: .value("Dimming limit", dimmingCap))
                .foregroundStyle(Self.dim.opacity(emphasis(.dimming)))
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            // Grips: what can be dragged looks like it. Each limit's grip sits by its own axis
            // (warmth left, dimming right), times' at the top.
            PointMark(x: .value("Time", span.lowerBound), y: .value("Warmth limit", warmthCap))
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
                AxisValueLabel(format: .dateTime.hour(), collisionResolution: .disabled).foregroundStyle(Color.white.opacity(0.5))
            }
        }
        .chartYAxis {
            // Left: warmth in Kelvin (compact; names took the plot's width, and the legend gives
            // the name too). Right: dimming on the schedule's fixed scale (to 30 %).
            AxisMarks(position: .leading, values: [0, Light.warmth(3400), Light.warmth(1900)]) { value in
                AxisGridLine().foregroundStyle(.white.opacity(0.1))
                // Same width both sides, so the plot sits centred; spaced off the plot so the
                // limits' grips at its edges never touch a label.
                AxisValueLabel(horizontalSpacing: 12) {
                    if let w = value.as(Double.self) {
                        Text(Format.kelvin(Light.kelvin(warmth: w))).frame(width: Self.axisWidth, alignment: .trailing)
                    }
                }
                    .foregroundStyle(Self.warm.opacity(0.8))
            }
            AxisMarks(position: .trailing, values: [0, 0.5, 1]) { value in
                AxisValueLabel(horizontalSpacing: 12) {
                    if let d = value.as(Double.self) { Text(Format.percent(d)).frame(width: Self.axisWidth, alignment: .leading) }
                }
                    .foregroundStyle(Self.dim.opacity(0.8))
            }
        }
        // Each side named, in its curve's colour: bare percentages next to Kelvin read ambiguous.
        .chartYAxisLabel(position: .leading, alignment: .top) {
            Text("Warmth").font(.system(size: 10, weight: .medium)).foregroundStyle(Self.warm.opacity(0.8))
        }
        .chartYAxisLabel(position: .trailing, alignment: .top) {
            Text("Dimming").font(.system(size: 10, weight: .medium)).foregroundStyle(Self.dim.opacity(0.8))
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onAppear { plotWidth = proxy.plotSize.width }
                    .onChange(of: proxy.plotSize.width) { _, width in plotWidth = width }
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
        // No hover help: the grips and cursor say what drags, and a tooltip popped over the curves.
        .keyboardRing($ring)
        .onMoveCommand { direction in
            guard ring else { ring = true; return }  // focus taken unseen: the first arrow shows it
            switch direction {
            case .left: step(keyMarker, by: -1)
            case .right: step(keyMarker, by: 1)
            case .up, .down: keyMarker = keyMarker == .bedtime ? .wake : .bedtime
            @unknown default: break
            }
        }
        .onDisappear(perform: endDrag)  // Settings closed mid-drag: nothing left held
        // VoiceOver: the plan, then bedtime and wake as adjustable steps (the graph is their only
        // control; the limits are adjustable in the legend).
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tonight")
        .accessibilityValue(e.plan)
        .accessibilityChildren {
            timeStep(String(localized: "Bedtime"), .bedtime)
            timeStep(String(localized: "Wake-up"), .wake)
        }
    }

    private func timeStep(_ title: String, _ marker: Handle) -> some View {
        Text(title)
            .accessibilityValue(Format.time(marker == .bedtime ? schedule.bedtime : schedule.wake))
            .accessibilityAdjustableAction { direction in step(marker, by: direction == .increment ? 1 : -1) }
    }

    /// Bedtime or wake a quarter hour later (+1) or earlier (−1), within its window.
    private func step(_ marker: Handle, by steps: Int) {
        let (path, window) = marker == .bedtime ? (\Schedule.bedtime, Schedule.bedtimes) : (\Schedule.wake, Schedule.wakes)
        let all = ClockTime.all(in: window)
        guard let i = all.firstIndex(of: schedule[keyPath: path]) else { return }
        schedule[keyPath: path] = all[min(all.count - 1, max(0, i + steps))]
    }

    private func marker(_ text: String) -> some View {
        Text(text).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).fixedSize()
    }

    private static func width(of text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .medium)]).width
    }

    private func emphasis(_ h: Handle) -> Double {
        dragging == h || (ring && keyMarker == h) ? 1 : hovered == h ? 0.85 : 0.6
    }

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

    /// A dragged limit in steps of 1 % of the scale, landing exactly on the range's end and on the
    /// recommended value when within a step (so dragging back to it is the default itself).
    private static func snapped(_ v: Double, in range: ClosedRange<Double>, snap: Double) -> Double {
        let r = range.clamp((v * 100).rounded() / 100)
        return abs(r - snap) < 0.01 ? snap : abs(r - range.upperBound) < 0.01 ? range.upperBound : r
    }

    private func endDrag() { (dragging, heldSpan, heldAnchor) = (nil, nil, nil) }

    private func drag(_ proxy: ChartProxy, _ geo: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                guard let plot = proxy.plotFrame.map({ geo[$0] }) else { return }
                if dragging == nil {
                    guard let h = handle(at: g.startLocation, proxy, geo) else { return }
                    // Anchored at 13:00 the day before this night's wake: any settable wake (04:00–12:00)
                    // or bedtime then still belongs to the same night. (Wake minus 18 h put a 04:00
                    // wake's anchor at 10:00, and a wake dragged past it jumped a night back.)
                    let cal = Calendar.current
                    heldAnchor = cal.date(byAdding: .day, value: -1, to: evening.wake)
                        .flatMap { cal.date(bySettingHour: 13, minute: 0, second: 0, of: $0) }
                    heldSpan = span
                    dragging = h
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
                    // Steps of 1 % of the scale, set only when one is crossed: a drag sends ~120
                    // events a second, and each new value redrew Settings and the chart.
                    let w = Self.snapped(v, in: warmthRange, snap: Self.recommended.warmth)
                    if abs(Light.warmth(schedule.warmest) - w) > 0.001 { schedule.warmest = Light.kelvin(warmth: w) }
                case .dimming:
                    guard let v: Double = proxy.value(atY: y) else { return }
                    let d = Self.snapped(v, in: dimmingRange, snap: Self.recommended.dimming)
                    if abs(Light.dimming(schedule.darkest) - d) > 0.001 { schedule.darkest = Light.brightness(dimming: d) }
                case nil: break
                }
            }
            .onEnded { _ in endDrag() }
    }
}
