import Foundation

/// Instants as the API sends them (`ISO8601DateTime`): RFC 3339, with or without fractional seconds, in any offset.
public enum ISO8601 {
    /// Parses `2026-10-06T20:00:00Z`, `2026-10-09T21:00:00.123-07:00` and the like; `nil` when `string` isn't one.
    public static func date(from string: String) -> Date? {
        // The style is strict about fractional seconds either way, so pick it by whether the time has them.
        let time = string.drop(while: { $0 != "T" })
        let fractional = time.contains(".")
        return try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: fractional))
    }

    /// Formats a date as the API would, in UTC without fractional seconds: `2026-10-06T20:00:00Z`.
    public static func string(from date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle())
    }

    /// Decodes a date from an ISO 8601 string, for `JSONDecoder.DateDecodingStrategy.custom`.
    public static func decode(from decoder: any Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let date = date(from: text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "\(text) isn't an ISO 8601 date")
        }
        return date
    }
}

public extension JSONDecoder {
    /// A decoder for the API's JSON: dates are ISO 8601 strings, fractional seconds or not. The SDK decodes with it
    /// unless a call is handed another; use it for your own models too.
    static var audienceKit: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(ISO8601.decode(from:))
        return decoder
    }
}

public extension JSONEncoder {
    /// An encoder that writes dates the way ``JSONDecoder/audienceKit`` reads them.
    static var audienceKit: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ISO8601.string(from: date))
        }
        return encoder
    }
}
