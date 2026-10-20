// Where the user is, without asking for Location Services.
//
// The default comes from the IANA zone table macOS ships (/usr/share/zoneinfo/zone.tab),
// which lists a representative coordinate for each time zone. That is accurate to well
// under an hour of sunset for almost everyone; users who want better can search a city.
// macOS still hands out old names the table no longer lists (India's Mac reports Asia/Calcutta,
// the table has Asia/Kolkata): those are found by having the same rules, not by a list of names.

import Foundation

public struct Place: Equatable, Sendable, Codable {
    public var name: String
    public var coordinate: Coordinate
    /// The place's own time zone (an IANA identifier), when known: a chosen city's.
    public var timeZone: String?
    public init(name: String, coordinate: Coordinate, timeZone: String? = nil) {
        self.name = name
        self.coordinate = coordinate
        self.timeZone = timeZone
    }

    /// Whether the place keeps the same time as `zone` at `date`. Everything runs on the Mac's
    /// clock (bedtime is 23:00 there), so a city in another zone, chosen or left behind by
    /// travel, put its sunset at odd hours of that clock and dragged the evening with it.
    /// Places without a known zone (the zone table's own) count as keeping it.
    public func keepsTime(of zone: TimeZone, at date: Date) -> Bool {
        guard let id = timeZone, let own = TimeZone(identifier: id) else { return true }
        return own.secondsFromGMT(for: date) == zone.secondsFromGMT(for: date)
    }

    /// Fallback when the zone table is unreadable: Greenwich.
    public static let greenwich = Place(name: "Greenwich", coordinate: Coordinate(latitude: 51.48, longitude: 0))

    public static func forTimeZone(_ zone: TimeZone = .current, table path: String = "/usr/share/zoneinfo/zone.tab",
                                   region: String? = Locale.current.region?.identifier) -> Place?
    {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return parse(zoneTab: text, zone: zone, region: region)
    }

    /// The zone's own row, else one with the same rules (an old name's new one), preferring the
    /// Mac's country (`region`), then the same area: America/Montreal's rules are also Nassau's,
    /// and Asia/Rangoon's also Indian/Cocos's.
    static func parse(zoneTab: String, zone: TimeZone, region: String? = nil) -> Place? {
        let rows = zoneTab.split(separator: "\n").filter { !$0.hasPrefix("#") }.compactMap { line -> (country: String, id: String, coordinate: Coordinate)? in
            let fields = line.split(separator: "\t")
            guard fields.count >= 3, let coordinate = parseISO6709(String(fields[1])) else { return nil }
            return (String(fields[0]), String(fields[2]), coordinate)
        }
        if let own = rows.first(where: { $0.id == zone.identifier }) { return place(own.id, own.coordinate) }
        let rules = { (id: String) in (TimeZone(identifier: id) as NSTimeZone?)?.data }
        let area = { (id: String) in id.split(separator: "/").first }
        let alike = rows.filter { rules($0.id) == (zone as NSTimeZone).data }
        let row = alike.first { $0.country == region } ?? alike.first { area($0.id) == area(zone.identifier) } ?? alike.first
        return row.map { place($0.id, $0.coordinate) }
    }

    private static func place(_ id: String, _ coordinate: Coordinate) -> Place {
        let city = id.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") }
        return Place(name: city ?? id, coordinate: coordinate)
    }

    /// "+5230+01322" (±DDMM±DDDMM) or "+404251-0740023" (±DDMMSS±DDDMMSS).
    static func parseISO6709(_ s: String) -> Coordinate? {
        guard let split = s.dropFirst().firstIndex(where: { $0 == "+" || $0 == "-" }) else { return nil }
        guard let lat = angle(s[..<split], degreeDigits: 2),
              let lon = angle(s[split...], degreeDigits: 3) else { return nil }
        return Coordinate(latitude: lat, longitude: lon)
    }

    private static func angle(_ s: Substring, degreeDigits: Int) -> Double? {
        guard let sign = s.first, sign == "+" || sign == "-" else { return nil }
        let digits = Array(s.dropFirst())
        guard digits.count == degreeDigits + 2 || digits.count == degreeDigits + 4,
              digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        func num(_ r: Range<Int>) -> Double { Double(String(digits[r]))! }
        var value = num(0..<degreeDigits) + num(degreeDigits..<degreeDigits + 2) / 60
        if digits.count == degreeDigits + 4 { value += num(degreeDigits + 2..<degreeDigits + 4) / 3600 }
        return sign == "-" ? -value : value
    }
}
