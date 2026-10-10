import Foundation

/// Everything an ``AudienceSession`` call can fail with.
public enum AudienceKitError: Error, Sendable, Equatable {
    /// There is no stored session; sign in first.
    case notSignedIn
    /// The API rejected the session token (HTTP 401): the person signed out elsewhere, removed the app
    /// from Facebook, or the session was revoked. The client has already forgotten the token; sign in again.
    case unauthorized
    /// `POST /v1/token` refused the Facebook token (HTTP 401): it's invalid, or it belongs to a Facebook
    /// app the audience doesn't use.
    case signInRejected
    /// `POST /v1/token` failed (HTTP 400). Carries the API's fault message when it sent one.
    case signInFailed(message: String?)
    /// The credentials are valid but not allowed here (HTTP 403), e.g. a session bound to another audience.
    case forbidden
    /// The audience, record or host doesn't exist (HTTP 404).
    case notFound
    /// Any other unsuccessful HTTP status.
    case http(status: Int)
    /// The request never got a response: offline, timed out, TLS failure and so on.
    case network(URLError)
    /// The response wasn't the JSON the SDK expected.
    case decoding(String)
    /// The GraphQL operation returned errors.
    case graphQL([GraphQLError])
    /// The configuration is missing something this call needs, e.g. ``AudienceKitConfiguration/host``.
    case missingConfiguration(String)
    /// The ``TokenStore`` couldn't save the session token.
    case tokenStorage(String)
    /// The API no longer serves this SDK version (HTTP 426): the app has to be updated. Carries the oldest SDK
    /// version the API accepts and its message for the person.
    case updateRequired(minimumSDKVersion: String, message: String?)
}

extension AudienceKitError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notSignedIn:
            "You're not signed in."
        case .unauthorized:
            "Your session has ended. Sign in again to continue."
        case .signInRejected:
            "Sign-in was refused. The Facebook login isn't valid for this app."
        case let .signInFailed(message):
            message ?? "Sign-in failed."
        case .forbidden:
            "You don't have access to this."
        case .notFound:
            "That isn't available."
        case let .http(status):
            "The server responded with status \(status)."
        case let .network(error):
            error.localizedDescription
        case let .decoding(detail):
            "The server sent a response the app didn't understand. \(detail)"
        case let .graphQL(errors):
            errors.map(\.message).joined(separator: "\n")
        case let .missingConfiguration(detail):
            "AudienceKit isn't configured: \(detail)"
        case let .tokenStorage(detail):
            "The session couldn't be saved on this device. \(detail)"
        case let .updateRequired(_, message):
            message ?? "This version of the app is out of date. Update it to keep going."
        }
    }
}

/// One entry of a GraphQL response's `errors` array.
public struct GraphQLError: Error, Codable, Sendable, Hashable {
    public var message: String
    /// The response path of the field that failed, e.g. `["venues", 0, "page"]`.
    public var path: [GraphQLValue]?
    /// Extra detail; validation failures map each field to its messages.
    public var extensions: [String: GraphQLValue]?

    public init(message: String, path: [GraphQLValue]? = nil, extensions: [String: GraphQLValue]? = nil) {
        self.message = message
        self.path = path
        self.extensions = extensions
    }
}
