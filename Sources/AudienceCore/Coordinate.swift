import Foundation

/// A latitude and longitude in degrees: a location's point, or the device's position for the GraphQL
/// `CoordinatesInput` (see ``coordinatesInput(beaconMajor:beaconMinor:)``).
public struct Coordinate: Codable, Sendable, Hashable {
    public let latitude: Double
    public let longitude: Double

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

    /// The point as WKT, the way the API serializes a `Geography`: `POINT (<longitude> <latitude>)`.
    public var wkt: String {
        "POINT (\(longitude) \(latitude))"
    }

    /// The value to pass as a `CoordinatesInput` variable, with the iBeacon the device is near, if any: a beacon's
    /// major value names a locale. Zero beacon values mean no beacon.
    public func coordinatesInput(beaconMajor: Int? = nil, beaconMinor: Int? = nil) -> GraphQLValue {
        var object: [String: GraphQLValue] = ["latitude": .double(latitude), "longitude": .double(longitude)]
        if let beaconMajor, beaconMajor != 0 { object["beaconMajor"] = .int(beaconMajor) }
        if let beaconMinor, beaconMinor != 0 { object["beaconMinor"] = .int(beaconMinor) }
        return .object(object)
    }

    /// ``coordinatesInput(beaconMajor:beaconMinor:)`` with no beacon.
    public var graphQLValue: GraphQLValue {
        coordinatesInput()
    }
}
