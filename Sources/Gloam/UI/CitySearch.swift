// Picking a city, for people whose time zone is a poor guess for where they are (a large
// zone, or travelling). Shared by Welcome and Settings. Results come from Apple Maps
// (MKLocalSearch), which receives only the typed name (Gloam's only other network use is the
// update check).

import GloamCore
import MapKit
import SwiftUI

struct CitySearch: View {
    let onPick: (Place) -> Void
    @State private var query = ""
    @State private var results: [Place] = []
    /// The search `results` answer: Return mustn't pick a result for what was typed before.
    @State private var resultsFor = ""
    @State private var searching = false
    /// The row under the pointer, and the one chosen with ↑ and ↓: apart, so a pointer resting
    /// on a row doesn't change what Return picks.
    @State private var hovered: Int?
    @State private var selected: Int?
    /// Return pressed before the results for what's typed arrived: picks the first once they do.
    @State private var pickWhenReady = false
    /// Why there are no results, when a search ran and found none or failed.
    @State private var status: String?
    @FocusState private var focused: Bool

    private var current: String { query.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Lamp.ink.opacity(0.5))
                    .accessibilityHidden(true)
                TextField("City", text: $query, prompt: Text("Search for a city").foregroundStyle(Lamp.ink.opacity(0.6)))
                    .textFieldStyle(.plain)
                    .foregroundStyle(Lamp.ink)
                    .focused($focused)
                    // Return picks the row chosen with ↑ and ↓, else the first (the rows are buttons,
                    // which Tab reaches only with keyboard navigation on). Pressed while the search
                    // still runs, it picks once the results for what's typed arrive.
                    .onSubmit {
                        guard resultsFor == current else { return pickWhenReady = current.count >= 2 }
                        if !results.isEmpty { onPick(results[min(selected ?? 0, results.count - 1)]) }
                    }
                    .onKeyPress(.downArrow) { move(1) }
                    .onKeyPress(.upArrow) { move(-1) }
                if searching { ProgressView().controlSize(.mini) }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.white.opacity(focused ? 0.22 : 0.1)))
            ForEach(Array(results.enumerated()), id: \.offset) { i, place in
                Button { onPick(place) } label: {
                    HStack {
                        Text(place.name).foregroundStyle(Lamp.ink.opacity(0.9))
                        Spacer()
                        Text(Geo.describe(place.coordinate)).font(.system(size: 11)).monospacedDigit()
                            .foregroundStyle(Lamp.ink.opacity(0.6))
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.white.opacity(highlighted == i ? 0.08 : 0)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 ? i : (hovered == i ? nil : hovered) }
            }
            if let status {
                Text(status).font(.system(size: 11)).lampInk(0.6)
                    .padding(.horizontal, 10).padding(.top, 2)
            }
        }
        .onAppear { focused = true }
        .onDisappear { pickWhenReady = false }  // cancelled meanwhile: a late result picks nothing
        // Searches as you type, after a short pause.
        // The old results stay until the new ones arrive (cleared, the window jumped at every key);
        // Return takes them only while they answer what's typed (`resultsFor`).
        .onChange(of: current) {
            selected = nil
            pickWhenReady = false
        }
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await search()
        }
    }

    /// One row lit at a time: the keyboard's choice (what Return picks), else the pointer's.
    private var highlighted: Int? { selected ?? hovered }

    private func move(_ step: Int) -> KeyPress.Result {
        guard !results.isEmpty else { return .ignored }
        selected = min(results.count - 1, max(0, (selected ?? -1) + step))
        return .handled
    }

    private func search() async {
        let text = current
        guard text.count >= 2 else { results = []; resultsFor = text; status = nil; searching = false; return }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        request.resultTypes = .address
        searching = true
        let items: [MKMapItem]?
        do { items = try await MKLocalSearch(request: request).start().mapItems } catch { items = nil }
        // Typed on meanwhile, or the field went away: the newer search (or nothing) owns the rest.
        guard !Task.isCancelled, text == current else { return }
        searching = false
        if text != resultsFor { hovered = nil; selected = nil }  // the same text again (a space typed): same rows
        resultsFor = text
        results = (items ?? []).lazy.compactMap { item -> Place? in
            let c = if #available(macOS 26, *) { item.location.coordinate } else { item.placemark.coordinate }
            // Maps can hand back an invalid (-180, -180) coordinate; it must never become the place.
            guard CLLocationCoordinate2DIsValid(c) else { return nil }
            return Place(name: item.name ?? text, coordinate: Coordinate(latitude: c.latitude, longitude: c.longitude),
                         timeZone: item.timeZone?.identifier)
        }.prefix(5).map { $0 }
        // MapKit reports "nothing found" as an error too; offline is the other common cause.
        status = results.isEmpty
            ? (items == nil ? String(localized: "No matching city (or no internet connection)") : String(localized: "No matching city")) : nil
        if pickWhenReady {
            pickWhenReady = false
            if !results.isEmpty { onPick(results[min(selected ?? 0, results.count - 1)]) }
        }
    }
}

enum Geo {
    static func describe(_ c: Coordinate) -> String {
        let degrees = { (v: Double) in abs(v).formatted(.number.precision(.fractionLength(1))) }
        let ns = c.latitude >= 0 ? String(localized: "N", comment: "north") : String(localized: "S", comment: "south")
        let ew = c.longitude >= 0 ? String(localized: "E", comment: "east") : String(localized: "W", comment: "west")
        return String(localized: "\(degrees(c.latitude))°\(ns) \(degrees(c.longitude))°\(ew)", comment: "52.5°N 13.4°E")
    }
}
