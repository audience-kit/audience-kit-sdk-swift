import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A change to the client's session.
public enum SessionEvent: Sendable, Equatable {
    /// ``AudienceSession/signIn(facebookAccessToken:device:)`` stored a new session.
    case signedIn
    /// ``AudienceSession/signOut()`` was called.
    case signedOut
    /// The API rejected the stored session (HTTP 401, or ``AudienceSession/sessionRejected(token:)`` for a socket or
    /// stream), e.g. after the person removed the app from Facebook or the token was issued for another endpoint. The
    /// token has been forgotten; show sign-in again. Yielded once per session, however many calls were refused.
    case sessionEnded
}

/// What a successful sign-in returns.
public struct SignInResult: Codable, Sendable, Hashable {
    public struct SignedInUser: Codable, Sendable, Hashable {
        public var id: String
        public var name: String?
    }

    /// The session JWT, already saved to the client's ``TokenStore``.
    public var token: String
    public var user: SignedInUser
}

/// An HTTP request to one of the API's REST endpoints, for calls the GraphQL schema doesn't cover yet
/// (sign-in and branding, for example).
public struct APIRequest: Sendable, Hashable {
    public var method: String
    /// The path under the base URL, e.g. `/v1/branding`.
    public var path: String
    public var queryItems: [URLQueryItem]
    /// A JSON body.
    public var body: Data?
    /// Whether to send the session token. A 401 on an authenticated request ends the session.
    public var authenticated: Bool

    public init(
        method: String = "GET",
        path: String,
        queryItems: [URLQueryItem] = [],
        body: Data? = nil,
        authenticated: Bool = true
    ) {
        self.method = method
        self.path = path
        self.queryItems = queryItems
        self.body = body
        self.authenticated = authenticated
    }
}

/// Talks to the AudienceKit API on behalf of one audience and one signed-in person.
///
/// The app owns Facebook Login; hand the resulting access token to
/// ``signIn(facebookAccessToken:device:)``. After that, every call carries the session token as
/// `Authorization: JWT <token>`. When the API rejects it, the call throws
/// ``AudienceKitError/unauthorized`` and ``sessionEvents`` yields ``SessionEvent/sessionEnded``.
public actor AudienceSession {
    public nonisolated let configuration: AudienceKitConfiguration

    /// Session changes, for the app to route between sign-in and content. Iterate it from one place.
    public nonisolated let sessionEvents: AsyncStream<SessionEvent>

    private nonisolated let sessionContinuation: AsyncStream<SessionEvent>.Continuation
    private let tokenStore: any TokenStore
    private let session: URLSession
    private var resolvedAudienceID: String?

    public init(
        configuration: AudienceKitConfiguration,
        tokenStore: any TokenStore = InMemoryTokenStore(),
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.tokenStore = tokenStore
        self.session = session
        (sessionEvents, sessionContinuation) = AsyncStream<SessionEvent>.makeStream()
    }

    deinit {
        sessionContinuation.finish()
    }

    // MARK: - Session

    /// Whether a session token is stored. It may still be rejected by the API.
    public var isSignedIn: Bool {
        (try? tokenStore.loadToken()) != nil
    }

    /// The stored session token, for the rare connection the SDK doesn't make itself (e.g. the
    /// Action Cable websocket). Never log it. When the API refuses it there, hand it to ``sessionRejected(token:)``.
    public func sessionToken() throws -> String? {
        try tokenStore.loadToken()
    }

    /// Exchanges a Facebook user access token for an AudienceKit session and stores it.
    ///
    /// Sends ``AudienceKitConfiguration/host`` and ``AudienceKitConfiguration/facebookAppID`` so the
    /// API checks the token against the right Facebook app and binds the session to the audience.
    @discardableResult
    public func signIn(facebookAccessToken: String, device: DeviceDescription) async throws -> SignInResult {
        try await signIn(SignInRequest(facebookToken: facebookAccessToken, host: configuration.host,
                                       facebookAppID: configuration.facebookAppID, device: device))
    }

    /// Exchanges the code from Facebook's OAuth dialog for an AudienceKit session and stores it.
    ///
    /// Use this with Facebook Login for Business, whose dialog takes the audience's
    /// ``Branding/facebookLoginConfigID`` as `config_id` and which the Facebook iOS SDK can't open. The API
    /// trades the code for a token with the app secret, so `redirectURI` must be exactly the one the dialog
    /// was opened with.
    @discardableResult
    public func signIn(facebookCode: String, redirectURI: String, device: DeviceDescription) async throws
        -> SignInResult
    {
        try await signIn(SignInRequest(code: facebookCode, redirectURI: redirectURI, host: configuration.host,
                                       facebookAppID: configuration.facebookAppID, device: device))
    }

    /// Exchanges a Sign in with Apple identity token for an AudienceKit session and stores it.
    ///
    /// Apple gives the person's name only the first time they sign in to the app; pass it then so the account
    /// has one. The account has no Facebook profile until ``connectFacebook(code:redirectURI:device:)``.
    @discardableResult
    public func signIn(appleIdentityToken: String, firstName: String? = nil, lastName: String? = nil,
                       device: DeviceDescription) async throws -> SignInResult
    {
        let body = AppleSignInRequest(identityToken: appleIdentityToken, firstName: firstName, lastName: lastName,
                                      host: configuration.host, device: device)
        return try await signIn(path: "/v1/token/apple", body: try JSONEncoder().encode(body), authenticated: false)
    }

    /// Connects Facebook to the signed-in account (one that signed in with Apple), with the code from Facebook's
    /// OAuth dialog, and stores the new session the API returns. When the Facebook profile already had an account,
    /// that account takes over the Apple sign-in, so the session can belong to a different user ID.
    @discardableResult
    public func connectFacebook(code: String, redirectURI: String, device: DeviceDescription) async throws
        -> SignInResult
    {
        var body = SignInRequest(code: code, redirectURI: redirectURI, host: configuration.host,
                                 facebookAppID: configuration.facebookAppID, device: device)
        body.connect = true
        return try await signIn(path: "/v1/token", body: try JSONEncoder().encode(body), authenticated: true)
    }

    private func signIn(_ body: SignInRequest) async throws -> SignInResult {
        try await signIn(path: "/v1/token", body: try JSONEncoder().encode(body), authenticated: false)
    }

    private func signIn(path: String, body: Data, authenticated: Bool) async throws -> SignInResult {
        let request = APIRequest(method: "POST", path: path, body: body, authenticated: authenticated)

        let (data, response) = try await perform(request)

        switch response.statusCode {
        case 200 ..< 300:
            break
        case 401:
            throw AudienceKitError.signInRejected
        case 400:
            let fault = try? JSONDecoder().decode(FaultEnvelope.self, from: data)
            throw AudienceKitError.signInFailed(message: fault?.fault.message)
        default:
            throw Self.error(forStatus: response.statusCode, data: data)
        }

        let result = try Self.decode(SignInResult.self, from: data)
        do {
            try tokenStore.saveToken(result.token)
        } catch {
            throw AudienceKitError.tokenStorage(String(describing: error))
        }
        resolvedAudienceID = nil
        sessionContinuation.yield(.signedIn)
        return result
    }

    /// Forgets the session on this device. (The Facebook session belongs to the app; log out of it too.)
    public func signOut() {
        try? tokenStore.deleteToken()
        resolvedAudienceID = nil
        sessionContinuation.yield(.signedOut)
    }

    // MARK: - Branding

    /// The audience's public branding for ``AudienceKitConfiguration/host`` (or `host`). No sign-in needed.
    public func branding(host: String? = nil) async throws -> Branding {
        guard let host = host ?? configuration.host else {
            throw AudienceKitError.missingConfiguration("branding needs a host")
        }

        let request = APIRequest(path: "/v1/branding", queryItems: [URLQueryItem(name: "host", value: host)],
                                 authenticated: false)
        let (data, response) = try await perform(request)
        guard (200 ..< 300).contains(response.statusCode) else {
            throw Self.error(forStatus: response.statusCode, data: data)
        }

        return try Self.decode(Branding.self, from: data)
    }

    // MARK: - Audience

    /// The audience this client queries: the configured ID, the session's `audience_id` claim, or the
    /// audience that owns the configured host.
    public func audienceID() async throws -> String {
        if let id = configuration.audienceID ?? resolvedAudienceID { return id }

        if let token = try? tokenStore.loadToken(), let id = Self.claims(of: token)?.audienceID {
            resolvedAudienceID = id
            return id
        }

        guard configuration.host != nil else {
            throw AudienceKitError.missingConfiguration("set an audienceID or a host")
        }

        let id = try await branding().audience.id
        resolvedAudienceID = id
        return id
    }

    // MARK: - GraphQL

    /// Runs a GraphQL operation against the audience's endpoint and decodes its `data`.
    ///
    /// Throws ``AudienceKitError/graphQL(_:)`` when the response carries errors, even alongside data.
    /// Pass a `decoder` to decode into the app's own models, e.g. with its date strategy. `endpoint` is the
    /// consumer view the apps use unless staff tools ask for ``GraphQLEndpoint/staff``.
    public func graphQL<Response: Decodable & Sendable>(
        _ query: String,
        variables: [String: GraphQLValue]? = nil,
        operationName: String? = nil,
        endpoint: GraphQLEndpoint = .consumer,
        as type: Response.Type = Response.self,
        decoder: JSONDecoder = JSONDecoder()
    ) async throws -> Response {
        let audienceID = try await audienceID()
        let body = try JSONEncoder().encode(
            GraphQLRequest(query: query, variables: variables, operationName: operationName)
        )
        let request = APIRequest(method: "POST", path: endpoint.path(audienceID: audienceID), body: body)

        let data = try await data(for: request)
        let envelope = try Self.decode(GraphQLResponse<Response>.self, from: data, decoder: decoder)

        if let errors = envelope.errors, !errors.isEmpty { throw AudienceKitError.graphQL(errors) }
        guard let result = envelope.data else { throw AudienceKitError.decoding("The response had no data.") }
        return result
    }

    // MARK: - REST

    /// Sends a request to a REST endpoint and returns the body of a successful response.
    public func data(for request: APIRequest) async throws -> Data {
        var token: String?
        if request.authenticated {
            guard let stored = try? tokenStore.loadToken() else { throw AudienceKitError.notSignedIn }
            token = stored
        }

        let (data, response) = try await perform(request, token: token)

        switch response.statusCode {
        case 200 ..< 300:
            return data
        case 401 where token != nil:
            sessionRejected(token: token)
            throw AudienceKitError.unauthorized
        default:
            throw Self.error(forStatus: response.statusCode, data: data)
        }
    }

    /// Resolves a URL the API sent (absolute, or a path relative to the base URL).
    public nonisolated func url(for string: String?) -> URL? {
        guard let string, !string.isEmpty else { return nil }
        return URL(string: string, relativeTo: configuration.baseURL)?.absoluteURL
    }

    /// Ends the session because the API refused `token`, for connections the SDK doesn't make itself: an Action Cable
    /// socket the server closed with `"reason": "unauthorized"`, or a Server-Sent Events stream answered with HTTP 401.
    /// (A 403 or a rejected channel subscription refuses that one thing, not the session; don't call this for them.)
    ///
    /// Forgets the token and yields ``SessionEvent/sessionEnded``, once: when the store no longer holds `token` (the
    /// session already ended, or the person has signed in again since) it does nothing and returns false.
    @discardableResult
    public func sessionRejected(token: String?) -> Bool {
        guard let token, let stored = try? tokenStore.loadToken(), stored == token else { return false }
        try? tokenStore.deleteToken()
        resolvedAudienceID = nil
        sessionContinuation.yield(.sessionEnded)
        return true
    }

    // MARK: - Private

    /// Sends `request`, with `token` when it's authenticated (by default the stored one).
    private func perform(_ request: APIRequest, token: String? = nil) async throws -> (Data, HTTPURLResponse) {
        let urlRequest = try makeURLRequest(request, token: token)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.audienceKitData(for: urlRequest)
        } catch let error as URLError {
            throw AudienceKitError.network(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AudienceKitError.decoding("The response wasn't HTTP.")
        }
        return (data, http)
    }

    private func makeURLRequest(_ request: APIRequest, token: String?) throws -> URLRequest {
        guard var components = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false) else {
            throw AudienceKitError.missingConfiguration("the base URL is invalid")
        }

        let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = basePath + (request.path.hasPrefix("/") ? request.path : "/" + request.path)
        components.queryItems = request.queryItems.isEmpty ? nil : request.queryItems

        guard let url = components.url else {
            throw AudienceKitError.missingConfiguration("couldn't build a URL for \(request.path)")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("AudienceKit-Swift/\(AudienceKitSDK.version)", forHTTPHeaderField: "X-AudienceKit-Client")
        if configuration.environment != .production {
            urlRequest.setValue(configuration.environment.rawValue,
                                forHTTPHeaderField: AudienceKitEnvironment.headerName)
        }

        if let body = request.body {
            urlRequest.httpBody = body
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        if request.authenticated, let token = token ?? (try? tokenStore.loadToken()) {
            urlRequest.setValue("JWT \(token)", forHTTPHeaderField: "Authorization")
        }

        return urlRequest
    }

    private static func error(forStatus status: Int, data: Data = Data()) -> AudienceKitError {
        switch status {
        case 401: .unauthorized
        case 403: .forbidden
        case 404: .notFound
        case 426:
            // Upgrade Required: the API no longer serves this SDK version.
            if let body = try? JSONDecoder().decode(UpdateRequiredBody.self, from: data) {
                .updateRequired(minimumSDKVersion: body.minimumSDKVersion ?? "", message: body.message)
            } else {
                .updateRequired(minimumSDKVersion: "", message: nil)
            }
        default: .http(status: status)
        }
    }

    private static func decode<T: Decodable>(
        _ type: T.Type,
        from data: Data,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw AudienceKitError.decoding(String(describing: error))
        }
    }

    /// The claims the client reads from a session JWT. The signature isn't checked; the API does that.
    static func claims(of token: String) -> SessionClaims? {
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return nil }

        var base64 = segments[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)

        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? JSONDecoder().decode(SessionClaims.self, from: data)
    }
}

// MARK: - Wire types

struct SessionClaims: Decodable {
    var audienceID: String?

    enum CodingKeys: String, CodingKey {
        case audienceID = "audience_id"
    }
}

struct SignInRequest: Encodable {
    var facebookToken: String?
    var code: String?
    var redirectURI: String?
    var host: String?
    var facebookAppID: String?
    var device: DeviceDescription
    /// Connect Facebook to the signed-in account rather than sign in as the Facebook profile's.
    var connect: Bool?

    init(facebookToken: String? = nil, code: String? = nil, redirectURI: String? = nil, host: String?,
         facebookAppID: String?, device: DeviceDescription)
    {
        self.facebookToken = facebookToken
        self.code = code
        self.redirectURI = redirectURI
        self.host = host
        self.facebookAppID = facebookAppID
        self.device = device
    }

    enum CodingKeys: String, CodingKey {
        case facebookToken = "facebook_token"
        case code
        case redirectURI = "redirect_uri"
        case host
        case facebookAppID = "facebook_app_id"
        case device
        case connect
    }
}

struct AppleSignInRequest: Encodable {
    var identityToken: String
    var firstName: String?
    var lastName: String?
    var host: String?
    var device: DeviceDescription

    enum CodingKeys: String, CodingKey {
        case identityToken = "identity_token"
        case firstName = "first_name"
        case lastName = "last_name"
        case host
        case device
    }
}

struct FaultEnvelope: Decodable {
    struct Fault: Decodable {
        var message: String?
    }

    var fault: Fault
}

/// The body of a 426: `{ "error": "update_required", "platform": "ios", "minimum_sdk_version": "0.3.0", "message": … }`.
struct UpdateRequiredBody: Decodable {
    var minimumSDKVersion: String?
    var message: String?

    enum CodingKeys: String, CodingKey {
        case minimumSDKVersion = "minimum_sdk_version"
        case message
    }
}

struct GraphQLRequest: Encodable {
    var query: String
    var variables: [String: GraphQLValue]?
    var operationName: String?
}

struct GraphQLResponse<Payload: Decodable>: Decodable {
    var data: Payload?
    var errors: [GraphQLError]?
}

extension URLSession {
    /// `data(for:)` via a data task, so the same code runs on Linux's Foundation.
    func audienceKitData(for request: URLRequest) async throws -> (Data, URLResponse) {
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = dataTask(with: request) { data, response, error in
                    if let error {
                        continuation.resume(throwing: error as? URLError ?? URLError(.unknown))
                    } else if let response {
                        continuation.resume(returning: (data ?? Data(), response))
                    } else {
                        continuation.resume(throwing: URLError(.badServerResponse))
                    }
                }
                box.set(task)
                task.resume()
            }
        } onCancel: {
            box.cancel()
        }
    }
}

private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var cancelled = false

    func set(_ task: URLSessionDataTask) {
        let cancelNow = lock.withLock {
            self.task = task
            return cancelled
        }
        if cancelNow { task.cancel() }
    }

    func cancel() {
        let task = lock.withLock {
            cancelled = true
            return self.task
        }
        task?.cancel()
    }
}
