import Foundation

/// Entry point for the AudienceKit client SDK.
///
/// Create an ``AudienceSession`` with an ``AudienceKitConfiguration``, sign the
/// person in with a Facebook access token your app obtained, then query the
/// audience's data over GraphQL.
public enum AudienceKitSDK {
    /// The SDK's semantic version.
    public static let version = "0.7.2"

    /// Whether this SDK is older than `minimum`, a dotted version like "0.3.0". Missing parts count as zero.
    public static func isOlder(than minimum: String, version: String = version) -> Bool {
        let parts = { (value: String) in value.split(separator: ".").map { Int($0) ?? 0 } }
        let mine = parts(version), theirs = parts(minimum)
        for index in 0 ..< max(mine.count, theirs.count) {
            let a = index < mine.count ? mine[index] : 0, b = index < theirs.count ? theirs[index] : 0
            if a != b { return a < b }
        }
        return false
    }

    /// The hosted AudienceKit API.
    public static let productionBaseURL = URL(string: "https://api.audiencekit.com")!
}
