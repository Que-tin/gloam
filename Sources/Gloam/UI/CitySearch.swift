// Picking a city, for people whose time zone is a poor guess for where they are (a large
// zone, or travelling). Shared by Welcome and Settings. Results come from Apple Maps
// (MKLocalSearch), which receives only the typed name; nothing else ever leaves the Mac.

import GloamCore
import MapKit
import SwiftUI

struct CitySearch: View {
    let onPick: (Place) -> Void
    @State private var query = ""
    @State private var results: [Place] = []
    @State private var searching = false
    @State private var hovered: Int?
    /// Why there are no results, when a search ran and found none or failed.
    @State private var status: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Lamp.ink.opacity(0.5))
                TextField("City", text: $query, prompt: Text("Search for a city").foregroundStyle(Lamp.ink.opacity(0.6)))
                    .textFieldStyle(.plain)
                    .foregroundStyle(Lamp.ink)
                    .focused($focused)
                    .onSubmit { if let first = results.first { onPick(first) } }
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
                        .fill(.white.opacity(hovered == i ? 0.08 : 0)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 ? i : (hovered == i ? nil : hovered) }
            }
            if let status {
                Text(status).font(.system(size: 11)).foregroundStyle(Lamp.ink.opacity(0.6))
                    .padding(.horizontal, 10).padding(.top, 2)
            }
        }
        .onAppear { focused = true }
        // Searches as you type, after a short pause; Return picks the first result.
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await search()
        }
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2 else { results = []; status = nil; searching = false; return }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        request.resultTypes = .address
        searching = true
        let items: [MKMapItem]?
        do { items = try await MKLocalSearch(request: request).start().mapItems } catch { items = nil }
        // Typed on meanwhile: the newer search owns the spinner and the results.
        guard text == query.trimmingCharacters(in: .whitespaces) else { return }
        searching = false
        hovered = nil
        results = (items ?? []).lazy.compactMap { item -> Place? in
            let c = if #available(macOS 26, *) { item.location.coordinate } else { item.placemark.coordinate }
            // Maps can hand back an invalid (-180, -180) coordinate; it must never become the place.
            guard CLLocationCoordinate2DIsValid(c) else { return nil }
            return Place(name: item.name ?? text, coordinate: Coordinate(latitude: c.latitude, longitude: c.longitude))
        }.prefix(5).map { $0 }
        // MapKit reports "nothing found" as an error too; offline is the other common cause.
        status = results.isEmpty
            ? (items == nil ? String(localized: "No matching city (or no internet connection)") : String(localized: "No matching city")) : nil
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
