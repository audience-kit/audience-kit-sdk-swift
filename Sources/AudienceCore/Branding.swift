import Foundation

/// What `GET /v1/branding?host=…` returns: who the audience is, its look, and the Facebook app its
/// sign-in uses. Public, so an app can skin itself before anyone signs in.
public struct Branding: Codable, Sendable, Hashable {
    public struct AudienceSummary: Codable, Sendable, Hashable {
        public var id: String
        public var name: String
        public var subdomain: String
    }

    /// An audience's theme as branding sends it: token overrides keyed by token name.
    public struct Theme: Codable, Sendable, Hashable {
        /// Design system preset, e.g. `default` or `hot_mess`.
        public var preset: String
        public var tagline: String?
        /// Light-mode overrides, e.g. `["accent": "#9c1c62"]`.
        public var light: [String: String]
        /// Dark-mode overrides.
        public var dark: [String: String]

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            preset = try container.decodeIfPresent(String.self, forKey: .preset) ?? "default"
            tagline = try container.decodeIfPresent(String.self, forKey: .tagline)
            light = try container.decodeIfPresent([String: String].self, forKey: .light) ?? [:]
            dark = try container.decodeIfPresent([String: String].self, forKey: .dark) ?? [:]
        }

        public init(preset: String, tagline: String? = nil, light: [String: String] = [:], dark: [String: String] = [:]) {
            self.preset = preset
            self.tagline = tagline
            self.light = light
            self.dark = dark
        }

        /// The value of a token, preferring the dark override in dark mode.
        public func color(_ token: String, dark isDark: Bool = false) -> RGBAColor? {
            let hex = isDark ? (dark[token] ?? light[token]) : light[token]
            return hex.flatMap(RGBAColor.init(hex:))
        }
    }

    public var audience: AudienceSummary
    public var facebookAppID: String?
    /// The Facebook Login for Business configuration to open the login dialog with, as `config_id`. A
    /// Business-type Facebook app refuses a login that asks for permissions without one.
    public var facebookLoginConfigID: String?
    public var theme: Theme

    enum CodingKeys: String, CodingKey {
        case audience
        case facebookAppID = "facebook_app_id"
        case facebookLoginConfigID = "facebook_login_config_id"
        case theme
    }
}

/// A color parsed from a `#rgb`, `#rrggbb` or `#rrggbbaa` hex string, with components from 0 to 1.
/// Convert it with `Color(red:green:blue:opacity:)` or `UIColor(red:green:blue:alpha:)`.
public struct RGBAColor: Sendable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public init?(hex: String) {
        var digits = hex.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") { digits.removeFirst() }
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard digits.count == 6 || digits.count == 8, let value = UInt64(digits, radix: 16) else { return nil }

        let rgba = digits.count == 6 ? value << 8 | 0xFF : value
        self.init(
            red: Double((rgba >> 24) & 0xFF) / 255,
            green: Double((rgba >> 16) & 0xFF) / 255,
            blue: Double((rgba >> 8) & 0xFF) / 255,
            alpha: Double(rgba & 0xFF) / 255
        )
    }
}
