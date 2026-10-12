import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A change to the client's session.
public enum SessionEvent: Sendable, Equatable {
    /// ``AudienceSession/signIn(facebookAccessToken:device:)`` (or another sign-in, ``AudienceSession/adopt(credential:)``
    /// or ``AudienceSession/switchAudience(to:)``) stored a new credential.
    case signedIn
    /// ``AudienceSession/signOut()`` was called.
    case signedOut
    /// The API rejected the stored session (HTTP 401, or ``AudienceSession/sessionRejected(token:)`` for a socket or
    /// stream), e.g. after the person removed the app from Facebook or the token was issued for another endpoint. The
    /// credential has been forgotten; show sign-in again. Yielded once per session, however many calls were refused.
    case sessionEnded
}

/// What a successful sign-in returns: the session's ``Credential``, already saved to the client's
/// ``CredentialStore``. The sign-in response has no profile; read `me { self }` for the person's name and photo.
public struct SignInResult: Sendable, Hashable {
    public let credential: Credential

    public init(credential: Credential) {
        self.credential = credential
    }

    /// The signed-in user's ID.
    public var userId: String { credential.userId }
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
/// `Authorization: Bearer <token>` and the API contract version as `X-AudienceKit-API-Version`. When the API
/// rejects the token, the call throws ``AudienceKitError/unauthorized`` and ``sessionEvents`` yields
/// ``SessionEvent/sessionEnded``.
public actor AudienceSession {
    public nonisolated let configuration: AudienceKitConfiguration

    private nonisolated let events = SessionEventBroadcaster()
    private nonisolated let credentialStore: any CredentialStore
    private let session: URLSession
    private var resolvedAudienceID: String?

    public init(
        configuration: AudienceKitConfiguration,
        credentialStore: any CredentialStore = InMemoryCredentialStore(),
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.credentialStore = credentialStore
        self.session = session
    }

    deinit {
        events.finish()
    }

    // MARK: - Session

    /// Session changes, for the app to route between sign-in and content. Each access is a new subscription that
    /// sees the events from then on, so any number of places can watch; it ends when the session is deallocated.
    public nonisolated var sessionEvents: AsyncStream<SessionEvent> {
        events.stream()
    }

    /// Whether a credential is stored. It may still be rejected by the API.
    public var isSignedIn: Bool {
        (try? credentialStore.load()) != nil
    }

    /// The stored credential: who is signed in, to which audience, and the token for the rare connection the SDK
    /// doesn't make itself (e.g. the Action Cable websocket). Never log the token. When the API refuses it there,
    /// hand it to ``sessionRejected(token:)``.
    public func credential() throws -> Credential? {
        try credentialStore.load()
    }

    /// The stored session token: ``credential()``'s.
    public func sessionToken() throws -> String? {
        try credentialStore.load()?.token
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
        case 400 where RESTErrorBody.decode(data)?.error != RESTErrorBody.unsupportedAPIVersion:
            let fault = RESTErrorBody.decode(data)
            throw AudienceKitError.signInFailed(message: fault?.message ?? fault?.fault?.message)
        default:
            throw Self.error(forStatus: response.statusCode, data: data)
        }

        let credential = try Self.decode(Credential.self, from: data)
        try store(credential)
        return SignInResult(credential: credential)
    }

    /// Makes `credential` the session: one minted outside the SDK, such as a venue device's, one the platform
    /// console handed over, or one the app refreshed itself. From now on GraphQL goes to the API instance the
    /// credential's `endpoint` names, for its `audienceId`. Yields ``SessionEvent/signedIn``.
    public func adopt(credential: Credential) throws {
        try store(credential)
    }

    /// Moves the session to another audience and returns its credential, which is stored and in use when this
    /// returns: `POST /v1/admin/choices { "audience_id": … }`, which swaps the session for one bound to that audience.
    /// The API allows it for sessions signed in on the platform console (no ``AudienceKitConfiguration/host``, the
    /// platform Facebook app); anyone else gets ``AudienceKitError/forbidden``. GraphQL then goes to the endpoint
    /// the new credential names.
    @discardableResult
    public func switchAudience(to audienceID: String) async throws -> Credential {
        let body = try JSONEncoder().encode(["audience_id": audienceID])
        let data = try await data(for: APIRequest(method: "POST", path: "/v1/admin/choices", body: body))
        let credential = try Self.decode(Credential.self, from: data)
        try store(credential)
        return credential
    }

    /// Saves a credential as the session and announces it.
    private func store(_ credential: Credential) throws {
        do {
            try credentialStore.save(credential)
        } catch {
            throw AudienceKitError.storage(String(describing: error))
        }
        resolvedAudienceID = nil
        events.yield(.signedIn)
    }

    /// Ends the session: forgets the credential on this device, yields ``SessionEvent/signedOut``, then revokes the
    /// token with `DELETE /v1/token` so it stops working everywhere. The device is signed out even when that call
    /// fails; the error says the token may still be alive on the server (offline, say), and a 401 or 404 (the
    /// session was already gone) is not an error. (The Facebook session belongs to the app; log out of it too.)
    public func signOut() async throws {
        let credential = try? credentialStore.load()
        try? credentialStore.delete()
        resolvedAudienceID = nil
        events.yield(.signedOut)

        guard let credential else { return }
        let (data, response) = try await perform(APIRequest(method: "DELETE", path: "/v1/token"),
                                                 token: credential.token)
        switch response.statusCode {
        case 200 ..< 300, 401, 404:
            return
        default:
            throw Self.error(forStatus: response.statusCode, data: data)
        }
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

    /// The audience this client queries: the stored credential's `audienceId`, else the configured ID, else the
    /// audience that owns the configured host.
    public func audienceID() async throws -> String {
        if let id = (try? credentialStore.load())?.audienceId { return id }
        if let id = configuration.audienceID ?? resolvedAudienceID { return id }

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
    /// The request goes to the API instance the stored credential's `endpoint` names (the configured base URL
    /// before sign-in), at the audience's `graphql` or `staffql` path: `endpoint` is the consumer view the apps use
    /// unless staff tools ask for ``GraphQLEndpoint/staff``. Throws ``AudienceKitError/graphQL(_:)`` when the
    /// response carries errors, even alongside data. Pass a `decoder` to decode into the app's own models with its
    /// own strategies; the default, ``Foundation/JSONDecoder/audienceKit``, reads ISO 8601 dates.
    public func graphQL<Response: Decodable & Sendable>(
        _ query: String,
        variables: [String: GraphQLValue]? = nil,
        operationName: String? = nil,
        endpoint: GraphQLEndpoint = .consumer,
        as type: Response.Type = Response.self,
        decoder: JSONDecoder = .audienceKit
    ) async throws -> Response {
        let credential = try? credentialStore.load()
        let audienceID = try await audienceID()
        let body = try JSONEncoder().encode(
            GraphQLRequest(query: query, variables: variables, operationName: operationName)
        )
        let request = APIRequest(method: "POST", path: endpoint.path(audienceID: audienceID), body: body)

        let data = try await data(for: request, baseURL: credential?.origin ?? configuration.baseURL)
        let envelope = try Self.decode(GraphQLResponse<Response>.self, from: data, decoder: decoder)

        if let errors = envelope.errors, !errors.isEmpty { throw AudienceKitError.graphQL(errors) }
        guard let result = envelope.data else { throw AudienceKitError.decoding("The response had no data.") }
        return result
    }

    // MARK: - Realtime

    /// A cable for this session's GraphQL subscriptions (``AudienceCable``): keep one for the app. Its socket opens
    /// on the API instance the stored credential names (the configured base URL before sign-in, or `url` when
    /// given), signed with the credential's token and the same headers as every call, and read again whenever it
    /// reconnects, so a new sign-in is picked up. A connection the server refuses as `unauthorized` ends the
    /// session the way an HTTP 401 does (``sessionRejected(token:)``). `endpoint` is the view its operations run in.
    public nonisolated func makeCable(endpoint: GraphQLEndpoint = .consumer, url: URL? = nil,
                                      session: URLSession = .shared, silenceLimit: Duration = .seconds(12))
        -> AudienceCable
    {
        let store = credentialStore
        return AudienceCable(configuration: configuration, endpoint: endpoint, url: url, session: session,
                             silenceLimit: silenceLimit, credential: { try? store.load() },
                             unauthorized: { [weak self] token in
                                 Task { await self?.sessionRejected(token: token) }
                             })
    }

    // MARK: - REST

    /// Sends a request to a REST endpoint and returns the body of a successful response.
    public func data(for request: APIRequest) async throws -> Data {
        try await data(for: request, baseURL: configuration.baseURL)
    }

    private func data(for request: APIRequest, baseURL: URL) async throws -> Data {
        var token: String?
        if request.authenticated {
            guard let stored = try? credentialStore.load() else { throw AudienceKitError.notSignedIn }
            token = stored.token
        }

        let (data, response) = try await perform(request, token: token, baseURL: baseURL)

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
    /// Forgets the credential and yields ``SessionEvent/sessionEnded``, once: when the store no longer holds `token`
    /// (the session already ended, or the person has signed in again since) it does nothing and returns false.
    @discardableResult
    public func sessionRejected(token: String?) -> Bool {
        guard let token, let stored = try? credentialStore.load(), stored.token == token else { return false }
        try? credentialStore.delete()
        resolvedAudienceID = nil
        events.yield(.sessionEnded)
        return true
    }

    // MARK: - Private

    /// Sends `request` to `baseURL` (the configured one by default), with `token` when it's authenticated (by
    /// default the stored one).
    private func perform(_ request: APIRequest, token: String? = nil, baseURL: URL? = nil) async throws
        -> (Data, HTTPURLResponse)
    {
        let urlRequest = try makeURLRequest(request, token: token, baseURL: baseURL ?? configuration.baseURL)

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

    private func makeURLRequest(_ request: APIRequest, token: String?, baseURL: URL) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
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
        let bearer = request.authenticated ? token ?? (try? credentialStore.load())?.token : nil
        urlRequest.setAudienceKitHeaders(environment: configuration.environment, token: bearer)

        if let body = request.body {
            urlRequest.httpBody = body
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        return urlRequest
    }

    /// The error for an unsuccessful REST status, reading the API's `{ "error": "<code>", "message": "…" }` body
    /// when it sent one.
    private static func error(forStatus status: Int, data: Data = Data()) -> AudienceKitError {
        let body = RESTErrorBody.decode(data)
        let message = body?.message ?? body?.fault?.message

        switch status {
        case 401:
            return .unauthorized
        case 403:
            guard let message else { return .forbidden }
            return AudienceKitError(code: AudienceKitError.Code.forbidden, message: message, status: 403)
        case 404:
            guard let message else { return .notFound }
            return AudienceKitError(code: AudienceKitError.Code.notFound, message: message, status: 404)
        case 400 where body?.error == RESTErrorBody.unsupportedAPIVersion:
            // The API no longer speaks this SDK's contract version; `supported` lists the ones it does.
            var text = message ?? "This version of the app is out of date. Update it to keep going."
            if let supported = body?.supported, !supported.isEmpty {
                text += " (API versions served: \(supported.joined(separator: ", ")).)"
            }
            return AudienceKitError(code: AudienceKitError.Code.unsupportedAPIVersion, message: text, status: 400)
        case 426:
            // Upgrade Required: the API no longer serves this SDK version.
            return .updateRequired(minimumSDKVersion: body?.minimumSDKVersion ?? "", message: message)
        default:
            let codes: [Int: String] = [
                400: AudienceKitError.Code.invalid, 409: AudienceKitError.Code.conflict,
                422: AudienceKitError.Code.invalid, 429: AudienceKitError.Code.rateLimited,
            ]
            var code = body?.error?.uppercased() ?? codes[status]
            if code == nil, status >= 500 { code = AudienceKitError.Code.internalError }
            return .http(status: status, code: code, message: message)
        }
    }

    private static func decode<T: Decodable>(
        _ type: T.Type,
        from data: Data,
        decoder: JSONDecoder = .audienceKit
    ) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw AudienceKitError.decoding(String(describing: error))
        }
    }
}

// MARK: - Session events

/// Fans ``SessionEvent``s out to every subscriber: each ``stream()`` is its own `AsyncStream`, fed from its
/// subscription on until it is cancelled or the broadcaster finishes.
final class SessionEventBroadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<SessionEvent>.Continuation] = [:]
    private var finished = false

    func stream() -> AsyncStream<SessionEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<SessionEvent>.makeStream()

        let alreadyFinished = lock.withLock { () -> Bool in
            if finished { return true }
            continuations[id] = continuation
            return false
        }
        if alreadyFinished {
            continuation.finish()
            return stream
        }

        continuation.onTermination = { [weak self] _ in
            self?.remove(id)
        }
        return stream
    }

    func yield(_ event: SessionEvent) {
        let subscribers = lock.withLock { Array(continuations.values) }
        for continuation in subscribers {
            continuation.yield(event)
        }
    }

    func finish() {
        let subscribers = lock.withLock { () -> [AsyncStream<SessionEvent>.Continuation] in
            finished = true
            let all = Array(continuations.values)
            continuations.removeAll()
            return all
        }
        for continuation in subscribers {
            continuation.finish()
        }
    }

    private func remove(_ id: UUID) {
        lock.withLock { _ = continuations.removeValue(forKey: id) }
    }
}

// MARK: - Wire types

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

/// The body of an unsuccessful REST response: `{ "error": "<code>", "message": "…" }`, plus what some carry: a
/// 400's `supported` API versions, a 426's `minimum_sdk_version`, and the sign-in fault envelope
/// `{ "fault": { "message": "…" } }`.
struct RESTErrorBody: Decodable {
    static let unsupportedAPIVersion = "unsupported_api_version"

    struct Fault: Decodable {
        var message: String?
    }

    var error: String?
    var message: String?
    var fault: Fault?
    var supported: [String]?
    var minimumSDKVersion: String?

    enum CodingKeys: String, CodingKey {
        case error, message, fault, supported
        case minimumSDKVersion = "minimum_sdk_version"
    }

    static func decode(_ data: Data) -> RESTErrorBody? {
        try? JSONDecoder().decode(RESTErrorBody.self, from: data)
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

extension URLRequest {
    /// Dresses a request the way every call to the API is dressed, the cable's handshake included: which SDK is
    /// calling (`X-AudienceKit-Client`), the contract version it speaks (`X-AudienceKit-API-Version`), the build's
    /// environment when it isn't production (`X-AudienceKit-Environment`), and the session as
    /// `Authorization: Bearer <token>` when there is one. For a connection the SDK doesn't make itself (a
    /// Server-Sent Events stream, say), pass ``AudienceSession/sessionToken()``.
    public mutating func setAudienceKitHeaders(environment: AudienceKitEnvironment = .production, token: String?) {
        setValue("AudienceKit-Swift/\(AudienceKitSDK.version)", forHTTPHeaderField: "X-AudienceKit-Client")
        setValue(AudienceKitSDK.apiVersion, forHTTPHeaderField: AudienceKitSDK.apiVersionHeaderName)
        if environment != .production {
            setValue(environment.rawValue, forHTTPHeaderField: AudienceKitEnvironment.headerName)
        }
        if let token {
            setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }
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
