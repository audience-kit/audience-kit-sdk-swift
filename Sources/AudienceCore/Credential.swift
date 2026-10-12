import Foundation

/// A session the API issued, as `POST /v1/token` (every variant) and `POST /v1/token/refresh` return it:
///
///     { "token": "...", "userId": "...", "audienceId": "...", "role": "member",
///       "endpoint": "https://api.audiencekit.com/v1/audience/<id>/graphql", "venueDeviceId": null, "expiresAt": null }
///
/// The credential says everything the client needs about the session, so nothing decodes the JWT: which audience it
/// is for, which GraphQL endpoint it was issued for (its `aud`: the consumer `graphql` or the staff `staffql`; a
/// token issued for a wider endpoint reaches the narrower ones), and when it expires, if ever. Treat the token like
/// a password: keep it in a ``CredentialStore`` backed by the keychain and never log it.
public struct Credential: Codable, Sendable, Hashable {
    /// The session JWT, sent as `Authorization: Bearer <token>`.
    public let token: String
    /// The signed-in user's ID (the JWT's `sub`).
    public let userId: String
    /// The audience the session is bound to. `nil` for a platform-console session, which belongs to no audience.
    public let audienceId: String?
    /// The user's role in the audience: `member`, `listing`, `admin` or `venue_device` today.
    public let role: String
    /// The GraphQL endpoint the token was issued for, as a full URL. Its origin is the API instance to talk to.
    public let endpoint: URL
    /// The venue device this session runs on, for venue-device sessions.
    public let venueDeviceId: String?
    /// When the session expires; `nil` when it only ends by signing out (the usual case).
    public let expiresAt: Date?
    /// The API version (``AudienceKitSDK/apiVersion``) the credential was issued under. Stored with it, so a client
    /// can tell a credential from before a contract break.
    public let apiVersion: String

    public init(
        token: String,
        userId: String,
        audienceId: String?,
        role: String,
        endpoint: URL,
        venueDeviceId: String? = nil,
        expiresAt: Date? = nil,
        apiVersion: String = AudienceKitSDK.apiVersion
    ) {
        self.token = token
        self.userId = userId
        self.audienceId = audienceId
        self.role = role
        self.endpoint = endpoint
        self.venueDeviceId = venueDeviceId
        self.expiresAt = expiresAt
        self.apiVersion = apiVersion
    }

    /// Whether the session has expired at `date`. Sessions with no `expiresAt` never do.
    public func isExpired(at date: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= date
    }

    /// The API instance ``endpoint`` is on: its scheme, host and port, and nothing else.
    public var origin: URL? {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: true) else { return nil }
        components.path = ""
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.url
    }

    /// Whether ``endpoint`` is an audience's staff endpoint (`staffql`).
    public var isStaff: Bool { endpoint.lastPathComponent == "staffql" }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case token, userId, audienceId, role, endpoint, venueDeviceId, expiresAt, apiVersion
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        token = try container.decode(String.self, forKey: .token)
        userId = try container.decode(String.self, forKey: .userId)
        audienceId = try container.decodeIfPresent(String.self, forKey: .audienceId)
        role = try container.decode(String.self, forKey: .role)
        let endpointText = try container.decode(String.self, forKey: .endpoint)
        guard let endpoint = URL(string: endpointText) else {
            throw DecodingError.dataCorruptedError(forKey: .endpoint, in: container,
                                                   debugDescription: "\(endpointText) isn't a URL")
        }
        self.endpoint = endpoint
        venueDeviceId = try container.decodeIfPresent(String.self, forKey: .venueDeviceId)
        if let expiresAtText = try container.decodeIfPresent(String.self, forKey: .expiresAt) {
            guard let date = ISO8601.date(from: expiresAtText) else {
                throw DecodingError.dataCorruptedError(forKey: .expiresAt, in: container,
                                                       debugDescription: "\(expiresAtText) isn't an ISO 8601 date")
            }
            expiresAt = date
        } else {
            expiresAt = nil
        }
        apiVersion = try container.decodeIfPresent(String.self, forKey: .apiVersion) ?? AudienceKitSDK.apiVersion
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(token, forKey: .token)
        try container.encode(userId, forKey: .userId)
        try container.encode(audienceId, forKey: .audienceId)
        try container.encode(role, forKey: .role)
        try container.encode(endpoint.absoluteString, forKey: .endpoint)
        try container.encode(venueDeviceId, forKey: .venueDeviceId)
        try container.encode(expiresAt.map(ISO8601.string(from:)), forKey: .expiresAt)
        try container.encode(apiVersion, forKey: .apiVersion)
    }
}
