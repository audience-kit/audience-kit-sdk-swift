@testable import AudienceCore
import Foundation
import Testing

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - The cable's protocol, over a socket the test drives

/// A socket the test feeds frames into and reads the cable's commands from.
private final class FakeSocket: CableSocket, @unchecked Sendable {
    let request: URLRequest
    private let lock = NSLock()
    private var sentFrames: [[String: Any]] = []
    private var closed = false
    private let incoming: AsyncStream<Data>
    private let feed: AsyncStream<Data>.Continuation
    private var iterator: AsyncStream<Data>.Iterator

    init(request: URLRequest) {
        self.request = request
        (incoming, feed) = AsyncStream<Data>.makeStream()
        iterator = incoming.makeAsyncIterator()
    }

    var sent: [[String: Any]] { lock.withLock { sentFrames } }
    var isClosed: Bool { lock.withLock { closed } }
    func commands(_ command: String) -> [[String: Any]] { sent.filter { $0["command"] as? String == command } }
    func push(_ frame: String) { feed.yield(Data(frame.utf8)) }

    func send(_ text: String) {
        let frame = (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
        lock.withLock { sentFrames.append(frame) }
    }

    func receive() async throws -> Data {
        guard let data = await iterator.next() else { throw URLError(.networkConnectionLost) }
        return data
    }

    func close() {
        lock.withLock { closed = true }
        feed.finish()
    }
}

private final class Sockets: @unchecked Sendable {
    private let lock = NSLock()
    private var opened: [FakeSocket] = []
    var all: [FakeSocket] { lock.withLock { opened } }
    func open(_ request: URLRequest) -> any CableSocket {
        let socket = FakeSocket(request: request)
        lock.withLock { opened.append(socket) }
        return socket
    }
}

private final class Refusals: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String?] = []
    var tokens: [String?] { lock.withLock { recorded } }
    func record(_ token: String?) { lock.withLock { recorded.append(token) } }
}

private func eventually(_ condition: () -> Bool) async throws {
    for _ in 0 ..< 400 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    #expect(condition())
}

private func json(_ object: [String: Any]) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

private let configuration = AudienceKitConfiguration(baseURL: URL(string: "https://api.test")!)

/// A session on `https://api.test`, for the audience's consumer endpoint, or its staff one on `https://staff.test`.
private func credential(_ token: String, staff: Bool = false) -> Credential {
    let endpoint = staff ? "https://staff.test/v1/audience/aud/staffql" : "https://api.test/v1/audience/aud/graphql"
    return Credential(token: token, userId: "u-1", audienceId: "aud", role: staff ? "admin" : "member",
                      endpoint: URL(string: endpoint)!)
}

@Suite struct AudienceCableProtocol {
    @Test func theAddressAndIdentifierAreStable() {
        #expect(AudienceCable.url(for: URL(string: "https://api.audiencekit.com")!).absoluteString
            == "wss://api.audiencekit.com/connection")
        #expect(AudienceCable.url(for: URL(string: "http://localhost:3000/")!).absoluteString
            == "ws://localhost:3000/connection")
        // Sorted keys, so the string Action Cable matches commands by never changes between sends.
        #expect(AudienceCable.graphQLIdentifier(audienceID: "aud", channelID: "c1")
            == #"{"audience_id":"aud","channel":"GraphQLChannel","channelId":"c1"}"#)
        #expect(AudienceCable.graphQLIdentifier(audienceID: "aud", channelID: "c1", endpoint: .staff)
            == #"{"audience_id":"aud","channel":"GraphQLChannel","channelId":"c1","endpoint":"staffql"}"#)
        #expect((0 ..< 20).allSatisfy { _ in
            AudienceCable.graphQLIdentifier(audienceID: "aud", channelID: "c1")
                == #"{"audience_id":"aud","channel":"GraphQLChannel","channelId":"c1"}"#
        })
    }

    @Test func aDevelopmentAddressAndEnvironmentAreHonoured() async throws {
        let sockets = Sockets()
        let staging = AudienceKitConfiguration(baseURL: URL(string: "https://api.test")!, environment: .staging)
        let cable = AudienceCable(configuration: staging, url: URL(string: "ws://localhost:3000/connection")!,
                                  credential: { credential("session-jwt") }, openSocket: { sockets.open($0) })
        let stream = await cable.subscribe(query: "subscription A { myNotifications { notificationId } }", audienceID: "aud")
        let socket = try #require(sockets.all.first)
        #expect(socket.request.url?.absoluteString == "ws://localhost:3000/connection")
        #expect(socket.request.value(forHTTPHeaderField: "Authorization") == "Bearer session-jwt")
        #expect(socket.request.value(forHTTPHeaderField: AudienceKitEnvironment.headerName) == "staging")
        _ = stream
    }

    @Test func theExecuteCommandCarriesTheOperation() throws {
        let data = AudienceCable.executeData(query: "subscription Room($id: ID!) { venueChat(venueId: $id) { __typename } }",
                                             variables: ["id": "v1"], operationName: "Room")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any])
        #expect(object["action"] as? String == "execute")
        #expect(object["operationName"] as? String == "Room")
        #expect(object["variables"] as? [String: String] == ["id": "v1"])
        #expect((object["query"] as? String)?.hasPrefix("subscription Room") == true)
    }

    @Test func backoffDoublesUpToHalfAMinute() {
        #expect(AudienceCable.reconnectDelay(afterFailures: 0) == .seconds(1))
        #expect(AudienceCable.reconnectDelay(afterFailures: 1) == .seconds(2))
        #expect(AudienceCable.reconnectDelay(afterFailures: 4) == .seconds(16))
        #expect(AudienceCable.reconnectDelay(afterFailures: 9) == .seconds(30))
    }

    @Test func runsAnOperationAndRunsItAgainAfterReconnecting() async throws {
        let sockets = Sockets()
        let cable = AudienceCable(configuration: configuration, endpoint: .staff,
                                  credential: { credential("session-jwt", staff: true) },
                                  openSocket: { sockets.open($0) })
        let door = """
        # endpoint: staff
        subscription StaffDoor($id: ID!) { door(venueId: $id) { __typename } }
        """
        var events = await cable.subscribe(query: door, variables: ["id": .string("v1")], operationName: "StaffDoor",
                                           audienceID: "aud").makeAsyncIterator()
        let first = try #require(sockets.all.first)
        // The socket opens on the API the credential names, dressed like every other call.
        #expect(first.request.url?.absoluteString == "wss://staff.test/connection")
        #expect(first.request.value(forHTTPHeaderField: "Authorization") == "Bearer session-jwt")
        #expect(first.request.value(forHTTPHeaderField: AudienceKitSDK.apiVersionHeaderName) == AudienceKitSDK.apiVersion)
        #expect(first.request.value(forHTTPHeaderField: "X-AudienceKit-Client") == "AudienceKit-Swift/\(AudienceKitSDK.version)")
        #expect(first.request.value(forHTTPHeaderField: AudienceKitEnvironment.headerName) == nil)

        // Subscribed to GraphQLChannel once welcomed, with the audience and a channel id of its own.
        first.push(#"{"type":"welcome"}"#)
        try await eventually { first.sent.count == 1 }
        #expect(first.sent[0]["command"] as? String == "subscribe")
        let identifier = try #require(first.sent[0]["identifier"] as? String)
        let params = try #require(JSONSerialization.jsonObject(with: Data(identifier.utf8)) as? [String: String])
        #expect(params["channel"] == "GraphQLChannel" && params["audience_id"] == "aud"
            && params["channelId"]?.isEmpty == false && params["endpoint"] == "staffql")

        // Executes once confirmed, and says so.
        first.push(json(["type": "confirm_subscription", "identifier": identifier]))
        guard case .subscribed? = await events.next() else { Issue.record("not subscribed"); return }
        #expect(first.sent.count == 2)
        #expect(first.sent[1]["command"] as? String == "message" && first.sent[1]["identifier"] as? String == identifier)
        let command = try #require(first.sent[1]["data"] as? String)
        let execute = try #require(JSONSerialization.jsonObject(with: Data(command.utf8)) as? [String: Any])
        #expect(execute["action"] as? String == "execute" && execute["operationName"] as? String == "StaffDoor")
        #expect((execute["variables"] as? [String: Any])?["id"] as? String == "v1")

        // Each result comes out of the stream.
        first.push(json(["identifier": identifier,
                         "message": ["result": ["data": ["door": ["__typename": "DoorOpened"]]], "more": true]]))
        guard case .result(let data)? = await events.next() else { Issue.record("no result"); return }
        #expect(String(decoding: data, as: UTF8.self).contains("DoorOpened"))

        // A drop says so, then the cable reconnects, subscribes the same operation again and executes it again.
        first.push(#"{"type":"disconnect","reason":"server_restart","reconnect":true}"#)
        guard case .disconnected(_, let reconnects)? = await events.next() else { Issue.record("no disconnect"); return }
        #expect(reconnects)
        try await eventually { sockets.all.count == 2 }
        let second = sockets.all[1]
        second.push(#"{"type":"welcome"}"#)
        try await eventually { second.sent.count == 1 }
        #expect(second.sent[0]["command"] as? String == "subscribe" && second.sent[0]["identifier"] as? String == identifier)
        second.push(json(["type": "confirm_subscription", "identifier": identifier]))
        guard case .subscribed? = await events.next() else { Issue.record("not subscribed again"); return }
        #expect(second.sent[1]["command"] as? String == "message")

        // `more: false` ends the operation: the stream finishes and the channel is left.
        second.push(json(["identifier": identifier,
                          "message": ["result": ["data": ["door": ["__typename": "DoorOpened"]]], "more": false]]))
        guard case .result? = await events.next() else { Issue.record("no last result"); return }
        #expect(await events.next() == nil)
        try await eventually { second.isClosed }
        #expect(second.sent.last?["command"] as? String == "unsubscribe")
    }

    @Test func operationsShareOneSocketAndEachHearsOnlyItsOwn() async throws {
        let sockets = Sockets()
        let cable = AudienceCable(configuration: configuration, credential: { credential("session-jwt") },
                                  openSocket: { sockets.open($0) })
        var chat = await cable.subscribe(query: "subscription { venueChat(venueId: \"v1\") { __typename } }",
                                         audienceID: "aud").makeAsyncIterator()
        let socket = try #require(sockets.all.first)
        socket.push(#"{"type":"welcome"}"#)
        try await eventually { socket.commands("subscribe").count == 1 }

        // An operation added once the socket is up subscribes straight away, on the same socket.
        var notifications = await cable.subscribe(query: "subscription { myNotifications { notificationId } }",
                                                  audienceID: "aud").makeAsyncIterator()
        try await eventually { socket.commands("subscribe").count == 2 }
        #expect(sockets.all.count == 1)

        let identifiers = socket.commands("subscribe").compactMap { $0["identifier"] as? String }
        #expect(Set(identifiers).count == 2)
        // The consumer view isn't named in the identifier.
        #expect(identifiers.allSatisfy { !$0.contains("endpoint") })
        let (chatID, notificationsID) = (identifiers[0], identifiers[1])

        socket.push(json(["type": "confirm_subscription", "identifier": notificationsID]))
        socket.push(json(["type": "confirm_subscription", "identifier": chatID]))
        guard case .subscribed? = await chat.next(), case .subscribed? = await notifications.next() else {
            Issue.record("not subscribed"); return
        }

        socket.push(json(["identifier": notificationsID,
                          "message": ["result": ["data": ["myNotifications": ["notificationId": "41"]]], "more": true]]))
        socket.push(json(["identifier": chatID,
                          "message": ["result": ["data": ["venueChat": ["__typename": "ChatJoined"]]], "more": true]]))
        guard case .result(let chatResult)? = await chat.next() else { Issue.record("no chat result"); return }
        #expect(String(decoding: chatResult, as: UTF8.self).contains("ChatJoined"))
        guard case .result(let notificationResult)? = await notifications.next() else {
            Issue.record("no notification"); return
        }
        #expect(String(decoding: notificationResult, as: UTF8.self).contains("41"))
    }

    @Test func aQuietSocketReconnectsOnceAndResubscribesEveryOperation() async throws {
        let sockets = Sockets()
        let cable = AudienceCable(configuration: configuration, silenceLimit: .milliseconds(200),
                                  credential: { credential("session-jwt") }, openSocket: { sockets.open($0) })
        var chat = await cable.subscribe(query: "subscription A { myNotifications { notificationId } }", audienceID: "aud").makeAsyncIterator()
        var notifications = await cable.subscribe(query: "subscription B { venueChat(venueId: \"v1\") { __typename } }", audienceID: "aud").makeAsyncIterator()
        let first = try #require(sockets.all.first)
        first.push(#"{"type":"welcome"}"#)
        try await eventually { first.commands("subscribe").count == 2 }
        let identifiers = Set(first.commands("subscribe").compactMap { $0["identifier"] as? String })

        // Nothing more from the server: the watchdog closes the socket and both operations hear it once.
        guard case .disconnected(_, true)? = await chat.next(),
              case .disconnected(_, true)? = await notifications.next()
        else { Issue.record("no drop"); return }
        #expect(first.isClosed)

        try await eventually { sockets.all.count == 2 }
        let second = sockets.all[1]
        second.push(#"{"type":"welcome"}"#)
        try await eventually { second.commands("subscribe").count == 2 }
        #expect(Set(second.commands("subscribe").compactMap { $0["identifier"] as? String }) == identifiers)
        #expect(sockets.all.count == 2)
    }

    @Test func theSocketClosesAfterTheLastOperationEnds() async throws {
        let sockets = Sockets()
        let cable = AudienceCable(configuration: configuration, credential: { credential("session-jwt") },
                                  openSocket: { sockets.open($0) })
        let first = Task {
            for await _ in await cable.subscribe(query: "subscription A { myNotifications { notificationId } }", audienceID: "aud") {}
        }
        let second = Task {
            for await _ in await cable.subscribe(query: "subscription B { venueChat(venueId: \"v1\") { __typename } }", audienceID: "aud") {}
        }
        try await eventually { sockets.all.count == 1 }
        let socket = sockets.all[0]
        socket.push(#"{"type":"welcome"}"#)
        try await eventually { socket.commands("subscribe").count == 2 }

        first.cancel()
        try await eventually { socket.commands("unsubscribe").count == 1 }
        #expect(!socket.isClosed)
        #expect(await cable.isOpen)

        second.cancel()
        try await eventually { socket.isClosed }
        #expect(!(await cable.isOpen))
        #expect(sockets.all.count == 1)
    }

    @Test func aRejectedChannelEndsOnlyItsOperation() async throws {
        let sockets = Sockets()
        let cable = AudienceCable(configuration: configuration, credential: { nil }, openSocket: { sockets.open($0) })
        var refused = await cable.subscribe(query: "subscription A { myNotifications { notificationId } }", audienceID: "other").makeAsyncIterator()
        let socket = try #require(sockets.all.first)
        // No credential: the configured API, unsigned.
        #expect(socket.request.url?.absoluteString == "wss://api.test/connection")
        #expect(socket.request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(socket.request.value(forHTTPHeaderField: AudienceKitSDK.apiVersionHeaderName) == AudienceKitSDK.apiVersion)
        socket.push(#"{"type":"welcome"}"#)
        try await eventually { socket.sent.count == 1 }
        let identifier = try #require(socket.sent[0]["identifier"] as? String)
        socket.push(json(["type": "reject_subscription", "identifier": identifier]))
        guard case .rejected? = await refused.next() else { Issue.record("not rejected"); return }
        #expect(await refused.next() == nil)
    }

    @Test func aRefusedConnectionEndsEveryOperationAndHandsBackTheToken() async throws {
        let sockets = Sockets()
        let refused = Refusals()
        let cable = AudienceCable(configuration: configuration, credential: { credential("revoked-jwt") },
                                  unauthorized: { refused.record($0) }, openSocket: { sockets.open($0) })
        var chat = await cable.subscribe(query: "subscription A { myNotifications { notificationId } }", audienceID: "aud").makeAsyncIterator()
        var notifications = await cable.subscribe(query: "subscription B { venueChat(venueId: \"v1\") { __typename } }", audienceID: "aud").makeAsyncIterator()
        let socket = try #require(sockets.all.first)
        socket.push(#"{"type":"disconnect","reason":"unauthorized","reconnect":false}"#)
        guard case .disconnected(let reason, let reconnects)? = await chat.next() else { Issue.record("no disconnect"); return }
        #expect(reason == "unauthorized" && !reconnects)
        #expect(await chat.next() == nil)
        guard case .disconnected(_, false)? = await notifications.next() else { Issue.record("no disconnect"); return }
        #expect(await notifications.next() == nil)
        #expect(refused.tokens == ["revoked-jwt"])
        #expect(socket.isClosed)
        try await Task.sleep(for: .milliseconds(50))
        #expect(sockets.all.count == 1)
    }

    @Test func aServerRestartIsNotASessionEnding() async throws {
        let sockets = Sockets()
        let refused = Refusals()
        let cable = AudienceCable(configuration: configuration, credential: { credential("session-jwt") },
                                  unauthorized: { refused.record($0) }, openSocket: { sockets.open($0) })
        var events = await cable.subscribe(query: "subscription A { myNotifications { notificationId } }", audienceID: "aud").makeAsyncIterator()
        let socket = try #require(sockets.all.first)
        socket.push(#"{"type":"disconnect","reason":"server_restart","reconnect":false}"#)
        guard case .disconnected? = await events.next() else { Issue.record("no disconnect"); return }
        #expect(refused.tokens.isEmpty)
    }

    @Test func framesAreReadLeniently() throws {
        let welcome = try #require(AudienceCable.parse(Data(#"{"type":"welcome"}"#.utf8)))
        #expect(welcome.type == "welcome")
        let bye = try #require(AudienceCable.parse(Data(#"{"type":"disconnect","reason":"unauthorized","reconnect":false}"#.utf8)))
        #expect(bye.reason == "unauthorized" && bye.reconnect == false)
        let frame = try #require(AudienceCable.parse(Data(#"{"identifier":"x","message":{"result":{"data":{"a":null}},"more":true}}"#.utf8)))
        #expect(frame.identifier == "x" && frame.more == true && frame.result != nil)
        #expect(AudienceCable.parse(Data("not json".utf8)) == nil)
        // A ping's message is a number, not a result.
        let ping = try #require(AudienceCable.parse(Data(#"{"type":"ping","message":1791691200}"#.utf8)))
        #expect(ping.result == nil)
    }
}
