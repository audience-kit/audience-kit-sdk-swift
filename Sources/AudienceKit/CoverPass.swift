import AudienceCore
import Foundation

#if canImport(CryptoKit)
import CryptoKit

/// The QR code on a cover pass, made on the device from ``Admission/passSecret`` so it works with no signal:
///
///     HMC1.<admission id>.<window>.<signature>
///
/// `window` is the Unix time divided by ``windowLength`` and `signature` is the first 16 characters of the unpadded
/// URL-safe Base64 HMAC-SHA256 of `"<admission id>.<window>"`, keyed with the Base64-decoded secret. The code
/// changes every 30 seconds, and the door accepts a couple of windows either side for clock drift.
public enum CoverPass {
    public static let prefix = "HMC1"
    /// Seconds each code lasts.
    public static let windowLength: Int = 30

    /// The window a moment falls in.
    public static func window(at date: Date) -> Int {
        Int((date.timeIntervalSince1970 / Double(windowLength)).rounded(.down))
    }

    /// The code to show at `date`, or `nil` when `secret` isn't Base64.
    public static func code(admissionID: String, secret: String, at date: Date = Date()) -> String? {
        guard let key = Data(base64Encoded: secret) else { return nil }
        let current = window(at: date)
        return [prefix, admissionID, String(current), signature(admissionID: admissionID, window: current, key: key)]
            .joined(separator: ".")
    }

    /// Seconds until the code shown at `date` changes.
    public static func secondsRemaining(at date: Date = Date()) -> Int {
        windowLength - Int(date.timeIntervalSince1970.rounded(.down)) % windowLength
    }

    static func signature(admissionID: String, window: Int, key: Data) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data("\(admissionID).\(window)".utf8),
                                                  using: SymmetricKey(data: key))
        let base64 = Data(mac).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return String(base64.prefix(16))
    }
}
#endif
