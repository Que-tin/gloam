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
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Lamp.ink.opacity(0.5))
                TextField("City", text: $query, prompt: Text("Search for a city").foregroundStyle(Lamp.ink.opacity(0.4)))
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
                            .foregroundStyle(Lamp.ink.opacity(0.45))
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
        guard text.count >= 2 else { results = []; return }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        request.resultTypes = .address
        searching = true
        defer { searching = false }
        let items = (try? await MKLocalSearch(request: request).start())?.mapItems ?? []
        guard text == query.trimmingCharacters(in: .whitespaces) else { return }  // typed on meanwhile
        results = items.prefix(5).map { item in
            let c = if #available(macOS 26, *) { item.location.coordinate } else { item.placemark.coordinate }
            return Place(name: item.name ?? text, coordinate: Coordinate(latitude: c.latitude, longitude: c.longitude))
        }
    }
}

enum Geo {
    static func describe(_ c: Coordinate) -> String {
        String(format: "%.1f°%@ %.1f°%@", abs(c.latitude), c.latitude >= 0 ? "N" : "S",
               abs(c.longitude), c.longitude >= 0 ? "E" : "W")
    }
}
