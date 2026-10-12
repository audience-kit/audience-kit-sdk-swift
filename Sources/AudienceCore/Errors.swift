import Foundation

/// Everything an ``AudienceSession`` call can fail with: a `code` from the API's vocabulary (or the SDK's own, for
/// failures before a response), a message for the person, and what detail there is.
///
/// Switch on ``code`` against the constants in ``Code``: the API's `UNAUTHENTICATED`, `FORBIDDEN`, `NOT_FOUND`,
/// `INVALID` (with per-field messages in ``fields``), `RATE_LIMITED`, `CONFLICT` and `INTERNAL`, which it sends as
/// `extensions.code` on GraphQL errors and as `error` on REST ones, plus the SDK's client-side codes. A code the SDK
/// doesn't know is passed through as the API sent it.
public struct AudienceKitError: Error, Sendable, Equatable {
    /// The error's code: one of ``Code``'s constants, or whatever the API sent.
    public let code: String
    /// A message for the person: the API's, or the SDK's default for the code.
    public let message: String
    /// The HTTP status of the response, when there was one.
    public let status: Int?
    /// `INVALID` only: the API's messages per field, from `extensions.fields`.
    public let fields: [String: [String]]
    /// The GraphQL response's `errors`, when the operation returned any; ``code`` and ``message`` are the first one's.
    public let errors: [GraphQLError]
    /// `NETWORK` only: why the request never got a response.
    public let underlying: URLError?
    /// `UPDATE_REQUIRED` only: the oldest SDK version the API still serves, when it said.
    public let minimumSDKVersion: String?

    public init(
        code: String,
        message: String,
        status: Int? = nil,
        fields: [String: [String]] = [:],
        errors: [GraphQLError] = [],
        underlying: URLError? = nil,
        minimumSDKVersion: String? = nil
    ) {
        self.code = code
        self.message = message
        self.status = status
        self.fields = fields
        self.errors = errors
        self.underlying = underlying
        self.minimumSDKVersion = minimumSDKVersion
    }

    /// The codes the SDK knows. The first group is the API's vocabulary; the rest are raised on the device.
    public enum Code {
        /// The API rejected the session (HTTP 401): the person signed out elsewhere, removed the app from Facebook,
        /// or the session was revoked. The client has already forgotten the credential; sign in again.
        public static let unauthenticated = "UNAUTHENTICATED"
        /// Signed in, but not allowed here (HTTP 403), e.g. a session bound to another audience, or no staff role.
        public static let forbidden = "FORBIDDEN"
        /// The audience, record or host doesn't exist (HTTP 404, or a null the API explains).
        public static let notFound = "NOT_FOUND"
        /// The input was refused; ``AudienceKitError/fields`` says which parts.
        public static let invalid = "INVALID"
        /// Too many requests (HTTP 429).
        public static let rateLimited = "RATE_LIMITED"
        /// The change clashed with the record's state (HTTP 409).
        public static let conflict = "CONFLICT"
        /// The API failed (HTTP 5xx, or a GraphQL error it couldn't classify).
        public static let internalError = "INTERNAL"

        /// There is no stored credential; sign in first.
        public static let notSignedIn = "NOT_SIGNED_IN"
        /// `POST /v1/token` refused the Facebook or Apple token (HTTP 401): it's invalid, or from an app the audience
        /// doesn't use.
        public static let signInRejected = "SIGN_IN_REJECTED"
        /// `POST /v1/token` failed (HTTP 400). The message is the API's when it sent one.
        public static let signInFailed = "SIGN_IN_FAILED"
        /// Any other unsuccessful HTTP status; see ``AudienceKitError/status``.
        public static let http = "HTTP"
        /// The request never got a response: offline, timed out, TLS failure and so on.
        public static let network = "NETWORK"
        /// The response wasn't the JSON the SDK expected.
        public static let decoding = "DECODING"
        /// A GraphQL error with no `extensions.code`, such as a validation failure of the document itself.
        public static let graphQL = "GRAPHQL"
        /// The configuration is missing something this call needs, e.g. ``AudienceKitConfiguration/host``.
        public static let missingConfiguration = "MISSING_CONFIGURATION"
        /// The credential store couldn't save or delete the session.
        public static let storage = "STORAGE"
        /// The API no longer serves this SDK version (HTTP 426): the app has to be updated.
        public static let updateRequired = "UPDATE_REQUIRED"
        /// The API no longer serves the API version this SDK speaks (HTTP 400 `unsupported_api_version`).
        public static let unsupportedAPIVersion = "UNSUPPORTED_API_VERSION"
    }

    // MARK: Values the SDK throws

    public static let notSignedIn = AudienceKitError(code: Code.notSignedIn, message: "You're not signed in.")
    public static let unauthorized = AudienceKitError(code: Code.unauthenticated,
                                                      message: "Your session has ended. Sign in again to continue.",
                                                      status: 401)
    public static let signInRejected = AudienceKitError(code: Code.signInRejected,
                                                        message: "Sign-in was refused. The login isn't valid for this app.",
                                                        status: 401)
    public static let forbidden = AudienceKitError(code: Code.forbidden, message: "You don't have access to this.",
                                                   status: 403)
    public static let notFound = AudienceKitError(code: Code.notFound, message: "That isn't available.", status: 404)

    public static func signInFailed(message: String?) -> AudienceKitError {
        AudienceKitError(code: Code.signInFailed, message: message ?? "Sign-in failed.", status: 400)
    }

    public static func http(status: Int, code: String? = nil, message: String? = nil) -> AudienceKitError {
        AudienceKitError(code: code ?? Code.http, message: message ?? "The server responded with status \(status).",
                         status: status)
    }

    public static func network(_ error: URLError) -> AudienceKitError {
        AudienceKitError(code: Code.network, message: error.localizedDescription, underlying: error)
    }

    public static func decoding(_ detail: String) -> AudienceKitError {
        AudienceKitError(code: Code.decoding, message: "The server sent a response the app didn't understand. \(detail)")
    }

    /// The GraphQL operation returned `errors`: the code and message are the first one's, and `INVALID` errors'
    /// `extensions.fields` become ``fields``.
    public static func graphQL(_ errors: [GraphQLError]) -> AudienceKitError {
        let first = errors.first
        var fields: [String: [String]] = [:]
        if case let .object(object)? = first?.extensions?["fields"] {
            for (field, value) in object {
                switch value {
                case let .array(messages):
                    fields[field] = messages.compactMap { message -> String? in
                        guard case let .string(text) = message else { return nil }
                        return text
                    }
                case let .string(text):
                    fields[field] = [text]
                default:
                    break
                }
            }
        }
        var code = Code.graphQL
        if case let .string(sent)? = first?.extensions?["code"] { code = sent }
        return AudienceKitError(code: code, message: first?.message ?? "The request failed.", fields: fields,
                                errors: errors)
    }

    public static func missingConfiguration(_ detail: String) -> AudienceKitError {
        AudienceKitError(code: Code.missingConfiguration, message: "AudienceKit isn't configured: \(detail)")
    }

    public static func storage(_ detail: String) -> AudienceKitError {
        AudienceKitError(code: Code.storage, message: "The session couldn't be saved on this device. \(detail)")
    }

    public static func updateRequired(minimumSDKVersion: String, message: String?) -> AudienceKitError {
        AudienceKitError(code: Code.updateRequired,
                         message: message ?? "This version of the app is out of date. Update it to keep going.",
                         status: 426, minimumSDKVersion: minimumSDKVersion)
    }

    /// Whether the API refused the session: ``Code/unauthenticated``.
    public var isUnauthenticated: Bool { code == Code.unauthenticated }
}

extension AudienceKitError: LocalizedError {
    public var errorDescription: String? { message }
}

/// One entry of a GraphQL response's `errors` array.
public struct GraphQLError: Error, Codable, Sendable, Hashable {
    public let message: String
    /// The response path of the field that failed, e.g. `["venues", 0, "page"]`.
    public let path: [GraphQLValue]?
    /// Extra detail: `code` (``AudienceKitError/Code``) and, for `INVALID`, `fields` mapping each field to its
    /// messages.
    public let extensions: [String: GraphQLValue]?

    public init(message: String, path: [GraphQLValue]? = nil, extensions: [String: GraphQLValue]? = nil) {
        self.message = message
        self.path = path
        self.extensions = extensions
    }

    /// `extensions.code`, when the API sent one.
    public var code: String? {
        guard case let .string(code)? = extensions?["code"] else { return nil }
        return code
    }
}
