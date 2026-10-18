// Where the user is, without asking for Location Services.
//
// The default comes from the IANA zone table macOS ships (/usr/share/zoneinfo/zone.tab),
// which lists a representative coordinate for each time zone. That is accurate to well
// under an hour of sunset for almost everyone; users who want better can search a city.

import Foundation

public struct Place: Equatable, Sendable, Codable {
    public var name: String
    public var coordinate: Coordinate
    public init(name: String, coordinate: Coordinate) {
        self.name = name
        self.coordinate = coordinate
    }

    /// Fallback when the zone table is unreadable: Greenwich.
    public static let greenwich = Place(name: "Greenwich", coordinate: Coordinate(latitude: 51.48, longitude: 0))

    public static func forTimeZone(_ zone: TimeZone = .current, table path: String = "/usr/share/zoneinfo/zone.tab")
        -> Place?
    {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return parse(zoneTab: text, identifier: zone.identifier)
    }

    static func parse(zoneTab: String, identifier: String) -> Place? {
        for line in zoneTab.split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t")
            guard fields.count >= 3, fields[2] == identifier,
                  let coordinate = parseISO6709(String(fields[1])) else { continue }
            let city = identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") }
            return Place(name: city ?? identifier, coordinate: coordinate)
        }
        return nil
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
