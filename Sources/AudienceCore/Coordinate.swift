import Foundation

/// A latitude and longitude in degrees.
public struct Coordinate: Codable, Sendable, Hashable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Parses a WKT point, `POINT (<longitude> <latitude>)`, optionally with an SRID prefix.
    public init?(wkt: String) {
        guard let open = wkt.firstIndex(of: "("), let close = wkt.lastIndex(of: ")"), open < close,
              wkt[..<open].uppercased().contains("POINT")
        else { return nil }

        let numbers = wkt[wkt.index(after: open) ..< close].split(whereSeparator: \.isWhitespace).compactMap {
            Double($0)
        }
        guard numbers.count >= 2 else { return nil }

        self.init(latitude: numbers[1], longitude: numbers[0])
    }
}
