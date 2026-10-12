import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The one Action Cable connection an app keeps to the API, carrying every GraphQL subscription it follows (chat
/// rooms, notifications, the door). Speaks graphql-ruby's protocol over `URLSessionWebSocketTask`. The socket opens
/// on the API instance the session's ``Credential`` names (its `endpoint`'s origin; the configured base URL before
/// sign-in) and its handshake is dressed like every other call (`Authorization: Bearer <token>`,
/// `X-AudienceKit-API-Version`, `X-AudienceKit-Client`; see the API's realtime docs). An app gets one from
/// ``AudienceSession/makeCable(endpoint:url:session:silenceLimit:)``.
///
/// Each operation from ``subscribe(query:variables:operationName:audienceID:)`` gets its own `GraphQLChannel`
/// subscription on the shared socket, told apart by a fresh `channelId`; once the server confirms it, the cable
/// performs `execute` with the operation, and every result the server sends back comes out of that operation's
/// stream. The socket opens on the first operation and closes after the last one ends, so an app whose subscriptions
/// live while it's in the foreground and signed in has the socket open exactly then.
///
/// One watchdog covers the socket: Action Cable pings every 3 seconds, so ``silenceLimit`` without a frame means the
/// socket is dead even if it looks open (a Wi-Fi to cellular handoff, say). A dead or dropped socket is closed, every
/// stream hears ``Event/disconnected(reason:reconnects:)``, and the cable reconnects with backoff, then subscribes and
/// executes every operation again, so a subscription that opens with a snapshot (`ChatJoined`, `DoorOpened`) refreshes
/// a screen that was offline for a while. The server closing the connection as `unauthorized` ends every stream and
/// hands the refused token to `unauthorized`, so the app signs out the way an HTTP 401 does.
///
/// Action Cable matches commands to subscriptions by the identifier *string*, byte for byte, so identifiers are built
/// once with sorted keys (``identifier(channel:params:)``), never from a dictionary at send time.
public actor AudienceCable {
    public enum Event: Sendable {
        /// The server confirmed the operation's channel and the operation went out: results arrive from now on.
        /// Sent again after every reconnect.
        case subscribed
        /// One GraphQL result (`{ "data": …, "errors": … }`, as JSON): a subscription's first event, then each one
        /// after. A result with errors and no data means the server refused the operation.
        case result(Data)
        /// The server turned the channel away (a token for another audience, or someone it banned). The stream ends
        /// after this.
        case rejected
        /// The socket dropped, went quiet, or the server closed it. The cable reconnects unless `reconnects` is
        /// false, in which case the stream ends after this (the session was revoked, say).
        case disconnected(reason: String?, reconnects: Bool)
    }

    /// Where the API mounts Action Cable.
    public static let path = "/connection"
    /// The channel that carries GraphQL.
    public static let channel = "GraphQLChannel"

    private struct Operation {
        let continuation: AsyncStream<Event>.Continuation
        /// The `execute` command's `data`, sent after every confirmation.
        let execute: String
    }

    private let configuration: AudienceKitConfiguration
    /// Where to open the socket when not the credential's API: a development override.
    private let address: URL?
    private let endpoint: GraphQLEndpoint
    private let openSocket: @Sendable (URLRequest) -> any CableSocket
    private let credential: @Sendable () -> Credential?
    private let unauthorized: @Sendable (String?) -> Void
    /// How long without a frame before the socket counts as gone.
    public nonisolated let silenceLimit: Duration
    /// The token the open socket was signed with, handed to `unauthorized` when the server refuses it.
    private var socketToken: String?
    private var socket: (any CableSocket)?
    /// Bumped whenever a socket opens or closes, so a late frame or failure from an old socket is ignored.
    private var generation = 0
    private var receiveTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var lastHeard = ContinuousClock.now
    private var welcomed = false
    private var attempts = 0
    private var operations: [String: Operation] = [:]

    /// `credential` is read whenever the socket (re)opens, so a renewed session is picked up without a new cable:
    /// the socket opens at ``url(for:)`` of the credential's ``Credential/origin`` (the configuration's `baseURL`
    /// when there is no credential), signed with its token, unless `url` names another address. `endpoint` is the
    /// view the operations run in (the staff tools' `staffql`, or the consumer apps' `graphql`); the HTTP client
    /// picks its endpoint the same way. `unauthorized` gets the token the server refused when it closes the
    /// connection as `unauthorized` (an ended session), so the owner can sign out.
    public init(configuration: AudienceKitConfiguration, endpoint: GraphQLEndpoint = .consumer, url: URL? = nil,
                session: URLSession = .shared, silenceLimit: Duration = .seconds(12),
                credential: @escaping @Sendable () -> Credential?,
                unauthorized: @escaping @Sendable (String?) -> Void = { _ in }) {
        self.init(configuration: configuration, endpoint: endpoint, url: url, silenceLimit: silenceLimit,
                  credential: credential, unauthorized: unauthorized) {
            WebSocketTaskSocket(session.webSocketTask(with: $0))
        }
    }

    /// A cable over another socket (tests drive the protocol with one).
    public init(configuration: AudienceKitConfiguration, endpoint: GraphQLEndpoint = .consumer, url: URL? = nil,
                silenceLimit: Duration = .seconds(12), credential: @escaping @Sendable () -> Credential?,
                unauthorized: @escaping @Sendable (String?) -> Void = { _ in },
                openSocket: @escaping @Sendable (URLRequest) -> any CableSocket) {
        self.configuration = configuration
        self.address = url
        self.endpoint = endpoint
        self.silenceLimit = silenceLimit
        self.credential = credential
        self.unauthorized = unauthorized
        self.openSocket = openSocket
    }

    /// The cable's address for an API base URL: `https://api.audiencekit.com` → `wss://api.audiencekit.com/connection`.
    public static func url(for baseURL: URL) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        components.path = path
        components.query = nil
        return components.url ?? baseURL
    }

    /// The subscription identifier Action Cable expects: a JSON object with the channel and its params, keys sorted
    /// so the same subscription always serializes to the same string.
    public static func identifier(channel: String, params: [String: String]) -> String {
        var object = params
        object["channel"] = channel
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// One operation's `GraphQLChannel` identifier: the audience it runs in, the id that keeps it apart, and, for the
    /// staff view, `"endpoint": "staffql"` (the consumer view is the server's default, so it isn't named).
    public static func graphQLIdentifier(audienceID: String, channelID: String,
                                         endpoint: GraphQLEndpoint = .consumer) -> String {
        var params = ["audience_id": audienceID, "channelId": channelID]
        if endpoint == .staff { params["endpoint"] = endpoint.rawValue }
        return identifier(channel: channel, params: params)
    }

    /// The `data` of the `execute` command that runs an operation, as the JSON string Action Cable carries.
    public static func executeData(query: String, variables: [String: GraphQLValue], operationName: String?) -> String {
        struct Execute: Encodable {
            let action = "execute"
            let query: String
            let variables: [String: GraphQLValue]
            let operationName: String?
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(Execute(query: query, variables: variables, operationName: operationName)))
            ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// Runs a GraphQL operation (a subscription, usually) in an audience over the cable. The stream yields each
    /// result the server sends and ends when the server finishes the operation (`more: false`), rejects the channel,
    /// or the session ends; ending the iteration unsubscribes, which ends the operation on the server.
    public func subscribe(query: String, variables: [String: GraphQLValue] = [:], operationName: String? = nil,
                          audienceID: String) -> AsyncStream<Event> {
        let identifier = Self.graphQLIdentifier(audienceID: audienceID, channelID: UUID().uuidString.lowercased(),
                                                endpoint: endpoint)
        let (stream, continuation) = AsyncStream<Event>.makeStream(bufferingPolicy: .unbounded)
        operations[identifier] = Operation(continuation: continuation,
                                           execute: Self.executeData(query: query, variables: variables,
                                                                     operationName: operationName))
        continuation.onTermination = { [weak self] _ in
            Task { await self?.remove(identifier) }
        }
        if socket == nil {
            if reconnectTask == nil { connect() }
        } else if welcomed {
            send(command: "subscribe", identifier: identifier)
        }
        return stream
    }

    /// Whether the socket is open (or opening). For tests and diagnostics.
    public var isOpen: Bool { socket != nil }

    /// Closes the socket and ends every stream, on signing out. Subscribing again reopens it.
    public func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        attempts = 0
        closeSocket()
        let ending = operations
        operations = [:]
        for (_, operation) in ending { operation.continuation.finish() }
    }

    // MARK: - Private

    private func remove(_ identifier: String) {
        guard operations.removeValue(forKey: identifier) != nil else { return }
        if welcomed { send(command: "unsubscribe", identifier: identifier) }
        if operations.isEmpty {
            reconnectTask?.cancel()
            reconnectTask = nil
            attempts = 0
            closeSocket()
        }
    }

    /// Ends an operation from this side: its stream finishes and the channel is left.
    private func finish(_ identifier: String) {
        guard let operation = operations[identifier] else { return }
        remove(identifier)
        operation.continuation.finish()
    }

    private func connect() {
        guard socket == nil else { return }
        let signedWith = credential()
        socketToken = signedWith?.token
        var request = URLRequest(url: address ?? Self.url(for: signedWith?.origin ?? configuration.baseURL))
        request.setAudienceKitHeaders(environment: configuration.environment, token: signedWith?.token)
        let socket = openSocket(request)
        self.socket = socket
        generation += 1
        let generation = generation
        welcomed = false
        lastHeard = .now
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await socket.receive()
                    guard let self else { return }
                    await self.handle(message, generation: generation)
                } catch {
                    guard !Task.isCancelled, let self else { return }
                    await self.socketFailed(error.localizedDescription, generation: generation)
                    return
                }
            }
        }
        watchdogTask = Task { [weak self, silenceLimit] in
            let interval = min(Duration.seconds(3), silenceLimit / 4)
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard let self else { return }
                if await self.isSilent(generation: generation) {
                    await self.socketFailed("The connection went quiet", generation: generation)
                    return
                }
            }
        }
    }

    private func isSilent(generation: Int) -> Bool {
        generation == self.generation && socket != nil && ContinuousClock.now - lastHeard > silenceLimit
    }

    private func closeSocket() {
        receiveTask?.cancel()
        receiveTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        socket?.close()
        socket = nil
        generation += 1
        welcomed = false
    }

    private func socketFailed(_ reason: String?, generation: Int) {
        guard generation == self.generation, socket != nil else { return }
        closeSocket()
        broadcast(.disconnected(reason: reason, reconnects: true))
        scheduleReconnect()
    }

    /// Exponential backoff from one second to half a minute, reset by the next welcome.
    private func scheduleReconnect() {
        guard !operations.isEmpty, reconnectTask == nil else { return }
        let delay = Self.reconnectDelay(afterFailures: attempts)
        attempts += 1
        reconnectTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            await self?.reconnectNow()
        }
    }

    /// How long to wait before reconnecting: a second, then doubling with each failure in a row, up to half a minute.
    public static func reconnectDelay(afterFailures failures: Int) -> Duration {
        .seconds(min(30, 1 << min(max(failures, 0), 5)))
    }

    private func reconnectNow() {
        reconnectTask = nil
        guard !operations.isEmpty, socket == nil else { return }
        connect()
    }

    private func send(command: String, identifier: String, data: String? = nil) {
        guard let socket else { return }
        var frame: [String: String] = ["command": command, "identifier": identifier]
        if let data { frame["data"] = data }
        guard let json = try? JSONSerialization.data(withJSONObject: frame, options: [.sortedKeys]) else { return }
        socket.send(String(decoding: json, as: UTF8.self))
    }

    private func handle(_ data: Data, generation: Int) {
        guard generation == self.generation else { return }
        lastHeard = .now
        guard let frame = Self.parse(data) else { return }
        switch frame.type {
        case "welcome":
            welcomed = true
            attempts = 0
            for identifier in operations.keys.sorted() { send(command: "subscribe", identifier: identifier) }
        case "confirm_subscription":
            guard let identifier = frame.identifier, let operation = operations[identifier] else { return }
            send(command: "message", identifier: identifier, data: operation.execute)
            operation.continuation.yield(.subscribed)
        case "reject_subscription":
            guard let identifier = frame.identifier, let operation = operations.removeValue(forKey: identifier) else { return }
            operation.continuation.yield(.rejected)
            operation.continuation.finish()
            if operations.isEmpty { closeSocket() }
        case "disconnect":
            let reconnects = frame.reconnect ?? true
            if reconnects {
                socketFailed(frame.reason, generation: generation)
            } else {
                let refused = socketToken
                closeSocket()
                broadcast(.disconnected(reason: frame.reason, reconnects: false))
                disconnect()
                // Action Cable's reject_unauthorized_connection: the session is gone, not just this channel.
                if frame.reason == "unauthorized" { unauthorized(refused) }
            }
        case "ping":
            break
        default:
            guard let identifier = frame.identifier, let operation = operations[identifier] else { return }
            if let result = frame.result { operation.continuation.yield(.result(result)) }
            if frame.more == false { finish(identifier) }
        }
    }

    private func broadcast(_ event: Event) {
        for (_, operation) in operations { operation.continuation.yield(event) }
    }

    // MARK: - Wire format

    /// One incoming frame: a protocol message (`type`), or a channel message (`identifier` + `message`), whose
    /// GraphQL `result` and `more` are pulled out.
    public struct Frame: Sendable {
        public var type: String?
        public var identifier: String?
        public var result: Data?
        public var more: Bool?
        public var reason: String?
        public var reconnect: Bool?
    }

    public static func parse(_ data: Data) -> Frame? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var frame = Frame(type: object["type"] as? String, identifier: object["identifier"] as? String,
                          reason: object["reason"] as? String, reconnect: object["reconnect"] as? Bool)
        if let message = object["message"] as? [String: Any] {
            frame.more = message["more"] as? Bool
            if let result = message["result"], JSONSerialization.isValidJSONObject(result) {
                frame.result = try? JSONSerialization.data(withJSONObject: result)
            }
        }
        return frame
    }
}

/// What the cable needs of a WebSocket: send text, receive frames, close. `URLSessionWebSocketTask` in the apps.
public protocol CableSocket: AnyObject, Sendable {
    func send(_ text: String)
    /// The next frame's bytes; throws once the socket is gone.
    func receive() async throws -> Data
    func close()
}

/// The apps' socket: a `URLSessionWebSocketTask`, started as soon as it's made.
public final class WebSocketTaskSocket: CableSocket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    public init(_ task: URLSessionWebSocketTask) {
        self.task = task
        task.resume()
    }

    public func send(_ text: String) { task.send(.string(text)) { _ in } }

    public func receive() async throws -> Data {
        switch try await task.receive() {
        case .string(let text): return Data(text.utf8)
        case .data(let data): return data
        @unknown default: return Data()
        }
    }

    public func close() { task.cancel(with: .goingAway, reason: nil) }
}
