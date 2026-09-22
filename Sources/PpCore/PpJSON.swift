import Foundation

/// One JSON convention for every file pp writes, so an export always re-imports to
/// exactly the same values.
///
/// Dates are stored as seconds from Foundation's reference date (2001-01-01), read with
/// `Date(timeIntervalSinceReferenceDate:)`. That is the number `Date` actually holds, so
/// the value that comes back is bit-for-bit the value that went out.
///
/// The obvious alternatives both lose information, and the loss is invisible until two
/// otherwise identical bundles disagree:
///
/// - ISO-8601 strings keep only milliseconds in Foundation, which is a visible drift.
/// - Seconds since 1970 keeps full double precision but still is not exact: converting to
///   a 1970-based double and back re-rounds against a ~9.8e8 offset, so roughly 40% of
///   wall-clock dates come back one ULP different. `Date` compares by its reference-date
///   double, so those two dates are simply not equal — the export "did not round-trip"
///   for reasons no test message can show, because both dates print identically.
public enum PpJSON {
    public static func encoder(pretty: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        if pretty { encoder.outputFormatting = [.prettyPrinted, .sortedKeys] }
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.timeIntervalSinceReferenceDate)
        }
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            Date(timeIntervalSinceReferenceDate: try decoder.singleValueContainer().decode(Double.self))
        }
        return decoder
    }
}
