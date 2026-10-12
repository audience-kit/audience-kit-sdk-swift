import Foundation

/// Which build of the app is calling. Staging builds talk to the production API but sign people in
/// with the audience's staging Facebook app; the client says so with the
/// `X-AudienceKit-Environment: staging` header. Development builds run against a local API, which
/// uses its own Facebook app, so they stay ``production``.
///
/// A value the SDK doesn't know (one a newer API or app defines) is kept as ``unknown(_:)`` and sent as is.
public enum AudienceKitEnvironment: Sendable, Hashable, RawRepresentable, Codable {
    case production
    case staging
    case unknown(String)

    /// The environments this SDK knows.
    public static let known: [AudienceKitEnvironment] = [.production, .staging]

    /// The header that carries the environment. Production builds leave it out.
    public static let headerName = "X-AudienceKit-Environment"

    public init(rawValue: String) {
        switch rawValue {
        case "production": self = .production
        case "staging": self = .staging
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .production: "production"
        case .staging: "staging"
        case let .unknown(value): value
        }
    }

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Where the SDK talks to and which audience it speaks for.
public struct AudienceKitConfiguration: Sendable, Hashable {
    /// The API's base URL, e.g. `https://api.audiencekit.com` or `http://localhost:3000`.
    public var baseURL: URL

    /// A host that names the audience, e.g. `hotmess.social` once that domain is verified, or
    /// `hotmess.admin.audiencekit.com`, which works as soon as the audience exists.
    ///
    /// Sent with sign-in, so the session is bound to the audience and the Facebook token is checked
    /// against the audience's Facebook apps, and used to look up ``Branding``. Without a host the API
    /// only accepts tokens from the AudienceKit platform Facebook app.
    public var host: String?

    /// The audience's ID (a UUID). When `nil` the client works it out from the stored ``Credential``'s
    /// `audienceId`, or from ``AudienceSession/branding()`` for ``host``.
    public var audienceID: String?

    /// The Facebook app the build signs people in with. The API only accepts the audience's own
    /// apps (production, staging, development) or the platform app.
    public var facebookAppID: String?

    /// The build's environment. ``AudienceKitEnvironment/staging`` makes the API sign people in with,
    /// and ``AudienceSession/branding()`` return, the audience's staging Facebook app.
    public var environment: AudienceKitEnvironment

    /// The prefix on the audience's cover pass QR codes (`<prefix>.<admission id>.<window>.<signature>`), which
    /// the door checks. ``AudienceKit/CoverPass/defaultPrefix`` unless the audience has its own.
    public var coverPassPrefix: String

    /// What to call the audience's fee on a cover charge (its `fee`) when showing the person the price breakdown,
    /// e.g. "Hot Mess fee".
    public var feeLabel: String

    public init(
        baseURL: URL = AudienceKitSDK.productionBaseURL,
        host: String? = nil,
        audienceID: String? = nil,
        facebookAppID: String? = nil,
        environment: AudienceKitEnvironment = .production,
        coverPassPrefix: String = "HMC1",
        feeLabel: String = "Service fee"
    ) {
        self.baseURL = baseURL
        self.host = host
        self.audienceID = audienceID
        self.facebookAppID = facebookAppID
        self.environment = environment
        self.coverPassPrefix = coverPassPrefix
        self.feeLabel = feeLabel
    }
}

/// The device a session is created on. The API records it alongside the session.
public struct DeviceDescription: Codable, Sendable, Hashable {
    /// A stable identifier for this install, e.g. `identifierForVendor`.
    public var identifier: String
    /// `apple` for iOS, iPadOS and macOS clients.
    public var type: String
    /// The hardware model, e.g. `iPhone17,1`.
    public var model: String?
    /// The app's marketing version.
    public var version: String?
    /// The app's build number.
    public var build: String?

    public init(
        identifier: String,
        type: String = "apple",
        model: String? = nil,
        version: String? = nil,
        build: String? = nil
    ) {
        self.identifier = identifier
        self.type = type
        self.model = model
        self.version = version
        self.build = build
    }
}
