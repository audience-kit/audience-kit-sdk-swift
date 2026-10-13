@testable import AudienceCore
import AudienceKitUI
import Foundation
import Testing
@testable import AudienceKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private let audienceID = "00000000-0000-4000-8000-000000000001"
private let device = DeviceDescription(identifier: "device-1", model: "iPhone17,1", version: "2.0", build: "42")

/// The API the request went to: its scheme and host, which is what a credential's endpoint names.
private func apiBase(of request: RecordedRequest) -> URL {
    URL(string: "\(request.url.scheme ?? "https")://\(request.url.host ?? "")")!
}

/// The URL of an audience's GraphQL endpoint on an API, as a credential names it.
private func endpointURL(on baseURL: URL, audienceId: String?, endpoint: GraphQLEndpoint = .consumer) -> URL {
    let path = audienceId.map { endpoint.path(audienceID: $0) } ?? "/v1/tenants/graphql"
    return URL(string: path, relativeTo: baseURL)!.absoluteURL
}

/// A credential as `POST /v1/token` would issue it for the API at `baseURL`, for the audience's consumer endpoint.
private func makeCredential(
    baseURL: URL,
    token: String = "session-token",
    audienceId: String? = audienceID,
    endpoint: GraphQLEndpoint = .consumer,
    role: String = "member"
) -> Credential {
    Credential(token: token, userId: "u-1", audienceId: audienceId, role: role,
               endpoint: endpointURL(on: baseURL, audienceId: audienceId, endpoint: endpoint))
}

/// The JSON `POST /v1/token` answers `request` with, for a session on the same API.
private func tokenJSON(_ request: RecordedRequest, token: String, userId: String = "u-1",
                       audienceId: String? = audienceID) -> String
{
    let audience = audienceId.map { "\"\($0)\"" } ?? "null"
    let endpoint = endpointURL(on: apiBase(of: request), audienceId: audienceId).absoluteString
    return #"{"token":"\#(token)","userId":"\#(userId)","audienceId":\#(audience),"role":"member","#
        + #""endpoint":"\#(endpoint)","venueDeviceId":null,"expiresAt":null}"#
}

private func makeClient(
    _ stub: Stub,
    host: String? = "hotmess.admin.audiencekit.com",
    audienceID: String? = audienceID,
    token: String? = "session-token",
    credentialAudienceID: String? = audienceID,
    environment: AudienceKitEnvironment = .production
) -> (AudienceKitClient, InMemoryCredentialStore) {
    let store = InMemoryCredentialStore(credential: token.map {
        makeCredential(baseURL: stub.baseURL, token: $0, audienceId: credentialAudienceID)
    })
    let configuration = AudienceKitConfiguration(baseURL: stub.baseURL, host: host, audienceID: audienceID,
                                                 facebookAppID: "100000000000001", environment: environment)
    return (AudienceKitClient(configuration: configuration, credentialStore: store, session: stub.session), store)
}

@Test func versionIsSet() {
    #expect(!AudienceKitSDK.version.isEmpty)
}

@Test func versionsCompareNumerically() {
    #expect(AudienceKitSDK.isOlder(than: "0.10.0", version: "0.9.9"))
    #expect(AudienceKitSDK.isOlder(than: "1", version: "0.2.0"))
    #expect(!AudienceKitSDK.isOlder(than: "0.2", version: "0.2.0"))
    #expect(!AudienceKitSDK.isOlder(than: "0.1.9", version: "0.2.0"))
    #expect(!AudienceKitSDK.isOlder(than: AudienceKitSDK.version))
}

@Suite struct SignIn {
    @Test func exchangesTheFacebookTokenAndStoresTheCredential() async throws {
        let stub = Stub { request in .json(status: 200, body: tokenJSON(request, token: "jwt-1")) }
        let (client, store) = makeClient(stub, token: nil)
        var events = client.sessionEvents.makeAsyncIterator()

        let result = try await client.signIn(facebookAccessToken: "fb-token", device: device)

        #expect(result.credential.token == "jwt-1")
        #expect(result.userId == "u-1")
        #expect(result.credential.audienceId == audienceID)
        #expect(result.credential.role == "member")
        #expect(result.credential.endpoint.path == "/v1/audience/\(audienceID)/graphql")
        #expect(result.credential.apiVersion == AudienceKitSDK.apiVersion)
        #expect(try store.load() == result.credential)
        #expect(try await client.credential() == result.credential)
        #expect(await client.isSignedIn)
        #expect(await events.next() == .signedIn)

        let request = try #require(stub.requests.first)
        #expect(request.method == "POST")
        #expect(request.path == "/v1/token")
        #expect(request.header("Authorization") == nil)
        #expect(request.header("Content-Type") == "application/json")
        #expect(request.header("X-AudienceKit-Environment") == nil)
        #expect(request.header("X-AudienceKit-API-Version") == "2026-10-11")
        #expect(request.header("X-AudienceKit-API-Version") == AudienceKitSDK.apiVersion)

        let body = try request.jsonBody()
        #expect(body["facebook_token"] as? String == "fb-token")
        #expect(body["host"] as? String == "hotmess.admin.audiencekit.com")
        #expect(body["facebook_app_id"] as? String == "100000000000001")

        let sentDevice = try #require(body["device"] as? [String: String])
        #expect(sentDevice == ["identifier": "device-1", "type": "apple", "model": "iPhone17,1",
                               "version": "2.0", "build": "42"])
    }

    @Test func stagingBuildsSayTheyAreStaging() async throws {
        let stub = Stub { request in .json(status: 200, body: tokenJSON(request, token: "jwt-1")) }
        let (client, _) = makeClient(stub, token: nil, environment: .staging)

        _ = try await client.signIn(facebookAccessToken: "fb-token", device: device)

        #expect(try #require(stub.requests.first).header("X-AudienceKit-Environment") == "staging")
    }

    @Test func leavesOutTheHostWhenNoneIsConfigured() async throws {
        let stub = Stub { request in .json(status: 200, body: tokenJSON(request, token: "jwt-1")) }
        let (client, _) = makeClient(stub, host: nil, token: nil)

        try await client.signIn(facebookAccessToken: "fb-token", device: device)

        let body = try #require(stub.requests.first).jsonBody()
        #expect(body["host"] == nil)
    }

    @Test func exchangesAnOAuthCode() async throws {
        let stub = Stub { request in .json(status: 200, body: tokenJSON(request, token: "jwt-2")) }
        let (client, store) = makeClient(stub, token: nil)

        try await client.signIn(facebookCode: "code-1", redirectURI: "fb123://authorize/", device: device)

        let body = try #require(stub.requests.first).jsonBody()
        #expect(body["code"] as? String == "code-1")
        #expect(body["redirect_uri"] as? String == "fb123://authorize/")
        #expect(body["facebook_token"] == nil)
        #expect(body["host"] as? String == "hotmess.admin.audiencekit.com")
        #expect(try store.load()?.token == "jwt-2")
    }

    @Test func signsInWithApple() async throws {
        let stub = Stub { request in .json(status: 200, body: tokenJSON(request, token: "jwt-3", userId: "u-2")) }
        let (client, store) = makeClient(stub, token: nil)

        let result = try await client.signIn(appleIdentityToken: "apple-jwt", firstName: "Ada", lastName: "Byron",
                                             device: device)

        #expect(result.userId == "u-2")
        #expect(try store.load()?.token == "jwt-3")
        let request = try #require(stub.requests.first)
        #expect(request.path == "/v1/token/apple")
        #expect(request.header("Authorization") == nil)
        let body = try request.jsonBody()
        #expect(body["identity_token"] as? String == "apple-jwt")
        #expect(body["first_name"] as? String == "Ada")
        #expect(body["last_name"] as? String == "Byron")
        #expect(body["host"] as? String == "hotmess.admin.audiencekit.com")
    }

    @Test func connectsFacebookToTheSignedInAccount() async throws {
        let stub = Stub { request in .json(status: 200, body: tokenJSON(request, token: "jwt-4", userId: "u-2")) }
        let (client, store) = makeClient(stub, token: "jwt-3")

        try await client.connectFacebook(code: "code-1", redirectURI: "fb123://authorize/", device: device)

        let request = try #require(stub.requests.first)
        #expect(request.path == "/v1/token")
        #expect(request.header("Authorization") == "Bearer jwt-3")
        let body = try request.jsonBody()
        #expect(body["connect"] as? Bool == true)
        #expect(body["code"] as? String == "code-1")
        #expect(try store.load()?.token == "jwt-4")
        #expect(try store.load()?.userId == "u-2")
    }

    @Test func aRejectedFacebookTokenIsNotASessionEnding() async throws {
        let stub = Stub { _ in .json(status: 401, body: "{}") }
        let (client, store) = makeClient(stub, token: nil)

        await #expect(throws: AudienceKitError.signInRejected) {
            try await client.signIn(facebookAccessToken: "bad", device: device)
        }
        #expect(try store.load() == nil)
    }

    @Test func surfacesTheFaultMessage() async throws {
        let stub = Stub { _ in .json(status: 400, body: #"{"fault":{"message":"Facebook token invalid"}}"#) }
        let (client, _) = makeClient(stub, token: nil)

        await #expect(throws: AudienceKitError.signInFailed(message: "Facebook token invalid")) {
            try await client.signIn(facebookAccessToken: "bad", device: device)
        }
    }

    @Test func surfacesTheRESTErrorMessage() async throws {
        let stub = Stub { _ in .json(status: 400, body: #"{"error":"invalid","message":"Facebook token invalid"}"#) }
        let (client, _) = makeClient(stub, token: nil)

        await #expect(throws: AudienceKitError.signInFailed(message: "Facebook token invalid")) {
            try await client.signIn(facebookAccessToken: "bad", device: device)
        }
    }

    @Test func anUnsupportedAPIVersionIsNotASignInFailure() async throws {
        let stub = Stub { _ in
            .json(status: 400, body: #"{"error":"unsupported_api_version","supported":["2027-01-01"]}"#)
        }
        let (client, _) = makeClient(stub, token: nil)

        do {
            try await client.signIn(facebookAccessToken: "fb", device: device)
            Issue.record("expected an error")
        } catch let error as AudienceKitError {
            #expect(error.code == AudienceKitError.Code.unsupportedAPIVersion)
            #expect(error.status == 400)
            #expect(error.message.contains("2027-01-01"))
        }
    }

    @Test func signOutForgetsTheCredentialAndRevokesTheToken() async throws {
        let stub = Stub { _ in .json(status: 204, body: "") }
        let (client, store) = makeClient(stub)
        var events = client.sessionEvents.makeAsyncIterator()

        try await client.signOut()

        #expect(try store.load() == nil)
        #expect(await client.isSignedIn == false)
        #expect(await events.next() == .signedOut)
        let request = try #require(stub.requests.first)
        #expect(request.method == "DELETE")
        #expect(request.path == "/v1/token")
        #expect(request.header("Authorization") == "Bearer session-token")
    }

    @Test func signOutIsLocalFirstAndReportsARevocationThatFailed() async throws {
        let stub = Stub { _ in .failure(URLError(.notConnectedToInternet)) }
        let (client, store) = makeClient(stub)
        var events = client.sessionEvents.makeAsyncIterator()

        do {
            try await client.signOut()
            Issue.record("expected an error")
        } catch let error as AudienceKitError {
            #expect(error.code == AudienceKitError.Code.network)
        }

        // Offline or not, the device is signed out; the token may still be alive on the server.
        #expect(try store.load() == nil)
        #expect(await events.next() == .signedOut)
    }

    @Test func signOutOfAnAlreadyEndedSessionIsFine() async throws {
        let stub = Stub { _ in .json(status: 401, body: "{}") }
        let (client, _) = makeClient(stub)

        try await client.signOut()
        // Nothing stored: nothing to revoke, but the app still hears it.
        var events = client.sessionEvents.makeAsyncIterator()
        try await client.signOut()
        #expect(await events.next() == .signedOut)
        #expect(stub.requests.count == 1)
    }

    @Test func everySubscriberHearsSessionEvents() async throws {
        let stub = Stub { request in .json(status: 200, body: tokenJSON(request, token: "jwt-1")) }
        let (client, _) = makeClient(stub, token: nil)
        var first = client.sessionEvents.makeAsyncIterator()
        var second = client.sessionEvents.makeAsyncIterator()

        try await client.signIn(facebookAccessToken: "fb-token", device: device)

        #expect(await first.next() == .signedIn)
        #expect(await second.next() == .signedIn)
    }

    @Test func adoptsACredentialMintedElsewhere() async throws {
        let stub = Stub { _ in .json(status: 200, body: #"{"data":{"venues":{"list":{"nodes":[]}}}}"#) }
        // The credential names another API instance, which is where the SDK then talks to.
        let other = Stub { _ in .json(status: 200, body: #"{"data":{"venues":{"list":{"nodes":[]}}}}"#) }
        let (client, store) = makeClient(stub, token: nil)
        var events = client.sessionEvents.makeAsyncIterator()
        let credential = makeCredential(baseURL: other.baseURL, token: "device-token", audienceId: "a-2",
                                        endpoint: .staff, role: "venue_device")

        try await client.adopt(credential: credential)
        _ = try await client.venues()

        #expect(try store.load() == credential)
        #expect(await events.next() == .signedIn)
        #expect(stub.requests.isEmpty)
        let request = try #require(other.requests.first)
        #expect(request.path == "/v1/audience/a-2/graphql")
        #expect(request.header("Authorization") == "Bearer device-token")
    }

    @Test func switchesAudiences() async throws {
        let stub = Stub { request in
            if request.path == "/v1/admin/choices" {
                return .json(status: 200, body: tokenJSON(request, token: "jwt-a2", audienceId: "a-2"))
            }
            return .json(status: 200, body: #"{"data":{"venues":{"list":{"nodes":[]}}}}"#)
        }
        let (client, store) = makeClient(stub, audienceID: nil, credentialAudienceID: nil)

        let credential = try await client.switchAudience(to: "a-2")
        _ = try await client.venues()

        #expect(credential.audienceId == "a-2")
        #expect(try store.load()?.token == "jwt-a2")
        let choice = try #require(stub.requests.first)
        #expect(choice.method == "POST")
        #expect(choice.header("Authorization") == "Bearer session-token")
        #expect(try choice.jsonBody()["audience_id"] as? String == "a-2")
        #expect(stub.requests.last?.path == "/v1/audience/a-2/graphql")
        #expect(stub.requests.last?.header("Authorization") == "Bearer jwt-a2")
    }
}

@Suite struct GraphQL {
    static let venuesResponse = #"""
    {"data":{"venues":{"list":{"nodes":[{
      "id":"Z2lkOi8vaG90LW1lc3MvVmVudWUvMTIz","name":null,"hidden":false,"order":3,
      "photoUrl":"/v1/photos/abc","bannerUrl":null,
      "profile":{"facebook":{"page":{"id":"p-1","name":"The Stud","photoUrl":"https://cdn.example/stud.jpg","bannerUrl":null}}},
      "locale":{"id":"l-1","name":"San Francisco","label":"SF","cityNames":null,"bannerUrl":null,
        "profile":{"places":{"placeId":"ChIJIQBpAG2ahYAR_6128GcTUEo"}}},
      "location":{"id":"loc-1","point":"POINT (-122.4194 37.7749)","places":{"placeId":"ChIJ-stud"}}
    },{
      "id":"v-2","name":"Pony","hidden":false,"order":4,"photoUrl":null,"bannerUrl":null,
      "profile":{"facebook":{"page":null}},
      "locale":{"id":"l-2","name":"Seattle","label":"SEA","cityNames":["Seattle","Capitol Hill"],"bannerUrl":null,
        "profile":{"places":{"placeId":null}}},
      "location":null,"tags":[{"id":"t-1","name":"Leather","color":"#222222"}]
    }]}}}}
    """#

    @Test func sendsTheSessionTokenToTheAudienceEndpoint() async throws {
        let stub = Stub { _ in .json(status: 200, body: Self.venuesResponse) }
        let (client, _) = makeClient(stub)

        let venues = try await client.venues()

        let request = try #require(stub.requests.first)
        #expect(request.method == "POST")
        #expect(request.path == "/v1/audience/\(audienceID)/graphql")
        #expect(request.header("Authorization") == "Bearer session-token")
        #expect(request.header("X-AudienceKit-API-Version") == AudienceKitSDK.apiVersion)

        let body = try request.jsonBody()
        #expect(body["operationName"] as? String == "Venues")
        #expect((body["query"] as? String)?.contains("venues") == true)

        #expect(venues.count == 2)
        let venue = try #require(venues.first)
        #expect(venue.name == "The Stud")
        #expect(venue.order == 3)
        #expect(venue.locale.label == "SF")
        #expect(venue.locale.googlePlaceId == "ChIJIQBpAG2ahYAR_6128GcTUEo")
        #expect(venue.location?.coordinate == Coordinate(latitude: 37.7749, longitude: -122.4194))
        #expect(venue.location?.googlePlaceId == "ChIJ-stud")
        #expect(client.url(for: venue.photoUrl) == stub.baseURL.appendingPathComponent("v1/photos/abc"))
        #expect(client.url(for: venue.page?.photoUrl) == URL(string: "https://cdn.example/stud.jpg"))

        // A venue added without a Facebook Page has its own name, and cityNames is a list.
        let pageless = try #require(venues.last)
        #expect(pageless.page == nil)
        #expect(pageless.name == "Pony")
        #expect(pageless.locale.cityNames == ["Seattle", "Capitol Hill"])
        #expect(pageless.locale.googlePlaceId == nil)

        // Encoding writes the profile mixin back, so a venue round-trips.
        #expect(try JSONDecoder().decode(Venue.self, from: JSONEncoder().encode(venue)) == venue)
        #expect(try JSONDecoder().decode(Venue.self, from: JSONEncoder().encode(pageless)) == pageless)

        #expect(venue.tags == nil)
        #expect(pageless.tags?.map(\.name) == ["Leather"])
        #expect(pageless.tags?.first?.color == "#222222")
    }

    @Test func staffToolsUseTheStaffEndpoint() async throws {
        struct Me: Decodable, Sendable { let me: State? ; struct State: Decodable, Sendable { let termsAcceptedAt: String? } }
        let stub = Stub { _ in .json(status: 200, body: #"{"data":{"me":{"termsAcceptedAt":null}}}"#) }
        let (client, _) = makeClient(stub)

        _ = try await client.graphQL("{ me { termsAcceptedAt } }", endpoint: .staff, as: Me.self)
        _ = try await client.graphQL("{ me { termsAcceptedAt } }", as: Me.self)

        #expect(stub.requests.map(\.path) == ["/v1/audience/\(audienceID)/staffql", "/v1/audience/\(audienceID)/graphql"])
        #expect(GraphQLEndpoint.allCases.map { $0.path(audienceID: "a") } == ["/v1/audience/a/graphql", "/v1/audience/a/staffql"])
    }

    @Test func sendsVariables() async throws {
        let stub = Stub { _ in .json(status: 200, body: #"{"data":{"node":{"__typename":"Venue","id":"v-1"}}}"#) }
        let (client, _) = makeClient(stub)

        let node = try await client.node(id: "v-1")

        #expect(node == Node(id: "v-1", typename: "Venue"))
        let body = try #require(stub.requests.first).jsonBody()
        #expect(body["variables"] as? [String: String] == ["id": "v-1"])
    }

    @Test func decodesPeopleMeAndTheAudience() async throws {
        let stub = Stub { request in
            let query = (try? request.jsonBody()["operationName"] as? String) ?? ""
            switch query {
            case "People":
                return .json(status: 200, body: #"""
                {"data":{"people":{"list":{"nodes":[{"id":"pe-1","order":1,"global":false,"likeRequired":true,
                  "profile":{"facebook":{"page":{"id":"p-2","name":"DJ Example","photoUrl":null,"bannerUrl":null}}},
                  "locales":[{"id":"l-2","name":"Portland"}]},
                  {"id":"pe-2","name":"DJ Nobody","avatarUrl":"/photos/person.jpg","bannerUrl":"/photos/banner.jpg","order":2,"global":false,"likeRequired":false,
                  "profile":{"facebook":{"page":null}},
                  "venues":{"home":{"id":"v-1","name":"Neighbours","photoUrl":null,"locale":{"id":"l-1","name":"Seattle"},
                    "friends":{"list":{"nodes":[{"id":"f-1","name":"Sam Okafor","facebookId":"123","presence":"ONLINE"}]}}}},
                  "events":{"involvements":{"edges":[
                    {"relationship":"TROUPE","role":"performer","via":{"id":"pe-9","name":"Those Bitches"},
                     "node":{"id":"e-1","name":"Drag Brunch","startAt":"2026-10-09T21:00:00-07:00",
                       "locale":{"id":"l-1","name":"Seattle"},
                       "venue":{"name":"Neighbours","venue":{"id":"v-1","name":"Neighbours","photoUrl":null}}}},
                    null,
                    {"relationship":"DIRECT","role":"host","via":null,
                     "node":{"id":"e-2","name":"Bingo","startAt":"2026-10-10T19:00:00-07:00",
                       "venue":{"name":"To be announced","venue":null}}}]}}}]}}}}
                """#)
            case "Me":
                return .json(status: 200, body: #"""
                {"data":{"me":{"self":{"id":"u-1","name":"Rick Mark","firstName":"Rick","lastName":"Mark",
                  "emailAddress":null,"isAdmin":true,"presence":"PUSH"}}}}
                """#)
            default:
                return .json(status: 200, body: #"""
                {"data":{"id":"a-1","name":"Hot Mess","subdomain":"hotmess",
                  "theme":{"preset":"hot_mess","tagline":"Queer nights out","light":[{"name":"accent","value":"#9c1c62"}],"dark":[]}}}
                """#)
            }
        }
        let (client, _) = makeClient(stub)

        let people = try await client.people()
        // Talent added by name has no Facebook Page yet.
        #expect(people.map(\.name) == ["DJ Example", "DJ Nobody"])
        #expect(people.last?.page == nil)
        #expect(people.last?.avatarUrl == "/photos/person.jpg")
        #expect(people.last?.bannerUrl == "/photos/banner.jpg")
        let roundTrip = try JSONDecoder().decode(AudienceKit.Person.self, from: JSONEncoder().encode(people.last!))
        #expect(roundTrip.avatarUrl == people.last?.avatarUrl)
        #expect(roundTrip.bannerUrl == people.last?.bannerUrl)
        #expect(people.first?.page?.id == "p-2")
        #expect(people.first?.likeRequired == true)
        // Featured locales, home venue and gigs place a person in a locale, with friends there now.
        #expect(people.first?.homeVenue == nil)
        #expect(people.first?.locales?.map(\.id) == ["l-2"])
        #expect(people.last?.locales == nil)
        #expect(people.last?.homeVenue?.locale?.id == "l-1")
        #expect(people.last?.homeVenue?.friends?.first?.name == "Sam Okafor")
        #expect(people.last?.homeVenue?.friends?.first?.presence == .online)
        // An event's venue comes in its mixin, with a name even while it's to be announced.
        #expect(people.last?.events?.first?.venue?.id == "v-1")
        #expect(people.last?.events?.last?.venue == nil)
        #expect(people.last?.events?.last?.venueName == "To be announced")
        #expect(people.last?.events?.first?.startAt == Date(timeIntervalSince1970: 1_791_604_800))
        // Their events include their troupes', and each says how they're on it.
        #expect(people.last?.events?.map(\.id) == ["e-1", "e-2"])
        #expect(people.last?.eventInvolvements?.map(\.relationship) == [.troupe, .direct])
        #expect(people.last?.eventInvolvements?.first?.via?.name == "Those Bitches")
        #expect(people.last?.eventInvolvements?.last?.via == nil)
        #expect(people.last?.eventInvolvements?.last?.role == "host")
        #expect(people.first?.events == nil)
        #expect(people.first?.eventInvolvements == nil)

        let me = try await client.me()
        #expect(me?.firstName == "Rick")
        #expect(me?.isAdmin == true)
        #expect(me?.presence == .push)

        let audience = try await client.audience()
        #expect(audience.subdomain == "hotmess")
        #expect(audience.theme?.light == [ThemeToken(name: "accent", value: "#9c1c62")])
    }

    @Test func buildsModelsByHandAndRoundTripsThem() throws {
        // Every model has a public memberwise initializer, so apps and previews can make one without JSON.
        let locale = AudienceLocale(id: "l-1", name: "Seattle", label: "SEA", googlePlaceId: "ChIJ-sea")
        let venue = Venue(id: "v-1", name: nil, hidden: false, order: 1, page: Page(id: "p-1", name: "Pony"),
                          locale: locale, location: Location(id: "loc-1", coordinate: Coordinate(latitude: 47.6, longitude: -122.3)),
                          tags: [Tag(id: "t-1", name: "Leather")])
        #expect(venue.name == "Pony")
        #expect(venue.location?.coordinate == Coordinate(latitude: 47.6, longitude: -122.3))
        #expect(try JSONDecoder().decode(Venue.self, from: JSONEncoder().encode(venue)) == venue)

        let event = PersonEvent(id: "e-1", name: "Bingo", startAt: Date(timeIntervalSince1970: 1_791_604_800),
                                venueName: "To be announced")
        let person = Person(id: "pe-1", name: "DJ Nobody", page: nil,
                            homeVenue: PersonVenue(id: "v-1", name: "Pony", locale: locale),
                            events: [event], eventInvolvements: [PersonEventInvolvement(event: event, role: "host")])
        #expect(person.name == "DJ Nobody")
        #expect(person.events?.first?.venue == nil)
        #expect(person.events?.first?.venueName == "To be announced")
        #expect(try JSONDecoder().decode(Person.self, from: JSONEncoder().encode(person)) == person)

        let usd = { (cents: Int) in Money(cents: cents, currency: "usd") }
        let admission = Admission(id: "ad-1", status: .paid, night: "2026-10-09", amount: usd(1000), total: usd(1112),
                                  profile: Profile(id: "u-1", name: "Rick M."),
                                  venue: CoverVenue(id: "v-1", name: "Pony"))
        let cover = VenueCover(id: "v-1", name: "Pony",
                               coverCharge: CoverCharge(amount: usd(1000), fee: usd(112), total: usd(1112),
                                                        night: "2026-10-09", payable: true),
                               viewerAdmission: admission)
        #expect(cover.viewerAdmission?.status == .paid)
        #expect(cover.coverCharge?.total == Money(cents: 1112, currency: "usd"))
        #expect(try JSONDecoder().decode(VenueCover.self, from: JSONEncoder().encode(cover)) == cover)
        #expect(DoorVenue(id: "v-1", door: DoorNight(night: "2026-10-09", paidCount: 1, checkedInCount: 0,
                                                       gross: usd(1000))).door?.paidCount == 1)
    }

    @Test func decodesAPersonsPlainEventsAndRoundTripsTheirInvolvements() throws {
        let plain = #"""
        {"id":"pe-1","order":1,"global":false,"likeRequired":false,"venues":{"home":null},
         "events":{"upcoming":{"nodes":[{"id":"e-1","name":"Solo"},null]}}}
        """#
        let person = try JSONDecoder().decode(Person.self, from: Data(plain.utf8))
        #expect(person.events?.map(\.id) == ["e-1"])
        #expect(person.eventInvolvements == nil)
        #expect(person.homeVenue == nil)

        let involved = #"""
        {"id":"pe-2","order":2,"global":false,"likeRequired":false,
         "venues":{"home":{"id":"v-1","name":"Neighbours"}},
         "events":{"involvements":{"edges":[
          {"relationship":"TROUPE","role":null,"via":{"id":"pe-9","name":"Those Bitches"},
           "node":{"id":"e-2","venue":{"name":"Neighbours","venue":{"id":"v-1"}}}},
          {"relationship":"DIRECT","role":null,"via":null,"node":null}]}}}
        """#
        let member = try JSONDecoder().decode(Person.self, from: Data(involved.utf8))
        let again = try JSONDecoder().decode(Person.self, from: JSONEncoder().encode(member))
        #expect(again == member)
        #expect(again.eventInvolvements?.first?.via?.id == "pe-9")
        #expect(again.events?.map(\.id) == ["e-2"])
        #expect(again.events?.first?.venue?.id == "v-1")
        #expect(again.events?.first?.venueName == "Neighbours")
        #expect(again.homeVenue?.name == "Neighbours")
    }

    @Test func throwsGraphQLErrorsWithTheirMessages() async throws {
        let stub = Stub { _ in
            .json(status: 200, body: #"""
            {"data":null,"errors":[{"message":"Field 'nope' doesn't exist on type 'Query'",
              "path":["query","nope"],"extensions":{"code":"undefinedField"}}]}
            """#)
        }
        let (client, _) = makeClient(stub)

        do {
            // The document is a real one; what's under test is how the stub's answer comes back.
            _ = try await client.graphQL("{ id }", as: [String: GraphQLValue].self)
            Issue.record("expected an error")
        } catch let error as AudienceKitError {
            // The code is whatever the API sent, known to the SDK or not.
            #expect(error.code == "undefinedField")
            #expect(error.message == "Field 'nope' doesn't exist on type 'Query'")
            #expect(error.errors.first?.path == ["query", "nope"])
            #expect(error.errors.first?.code == "undefinedField")
            #expect(error.fields.isEmpty)
        }
    }

    @Test func carriesTheAPIsErrorCodeAndFields() async throws {
        let stub = Stub { _ in
            .json(status: 200, body: #"""
            {"data":null,"errors":[{"message":"Name can't be blank","path":["rsvpEvent"],
              "extensions":{"code":"INVALID","fields":{"name":["can't be blank"],"order":"must be a number"}}}]}
            """#)
        }
        let (client, _) = makeClient(stub)

        do {
            let document = "mutation { rsvpEvent(input: { eventId: \"e-1\", state: ATTENDING }) { event { id } } }"
            _ = try await client.graphQL(document, as: [String: GraphQLValue].self)
            Issue.record("expected an error")
        } catch let error as AudienceKitError {
            #expect(error.code == AudienceKitError.Code.invalid)
            #expect(error.fields == ["name": ["can't be blank"], "order": ["must be a number"]])
            #expect(error.errorDescription == "Name can't be blank")
        }

        let noCode = AudienceKitError.graphQL([GraphQLError(message: "Boom")])
        #expect(noCode.code == AudienceKitError.Code.graphQL)
        #expect(noCode.message == "Boom")
    }

    @Test func aRejectedSessionEndsIt() async throws {
        let stub = Stub { _ in .json(status: 401, body: "{}") }
        let (client, store) = makeClient(stub)
        var events = client.sessionEvents.makeAsyncIterator()

        await #expect(throws: AudienceKitError.unauthorized) { try await client.venues() }

        #expect(try store.load() == nil)
        #expect(await client.isSignedIn == false)
        #expect(await events.next() == .sessionEnded)
        #expect(AudienceKitError.unauthorized.code == AudienceKitError.Code.unauthenticated)
        #expect(AudienceKitError.unauthorized.isUnauthenticated)
        #expect(AudienceKitError.unauthorized.status == 401)
    }

    @Test func manyRejectedCallsEndTheSessionOnce() async throws {
        let stub = Stub { _ in .json(status: 401, body: "{}") }
        let (client, _) = makeClient(stub)

        var events = client.sessionEvents.makeAsyncIterator()

        await #expect(throws: AudienceKitError.unauthorized) { try await client.venues() }
        // Signed out now, so later calls don't reach the API at all.
        await #expect(throws: AudienceKitError.notSignedIn) { try await client.people() }
        #expect(await client.sessionRejected(token: "session-token") == false)
        try await client.signOut()

        #expect(await events.next() == .sessionEnded)
        #expect(await events.next() == .signedOut)
        #expect(stub.requests.count == 1)
    }

    @Test func aRefusalOfAnOlderTokenKeepsANewerSession() async throws {
        let store = InMemoryCredentialStore()
        let stub = Stub { request in
            // The person signed in again while the old token's call was in flight.
            _ = try? store.save(makeCredential(baseURL: apiBase(of: request), token: "newer-token"))
            return .json(status: 401, body: "{}")
        }
        try store.save(makeCredential(baseURL: stub.baseURL, token: "session-token"))
        let configuration = AudienceKitConfiguration(baseURL: stub.baseURL, audienceID: audienceID)
        let client = AudienceKitClient(configuration: configuration, credentialStore: store, session: stub.session)

        await #expect(throws: AudienceKitError.unauthorized) { try await client.venues() }

        #expect(try store.load()?.token == "newer-token")
        #expect(stub.requests.first?.header("Authorization") == "Bearer session-token")
    }

    @Test func aSocketTheServerRefusedEndsTheSession() async throws {
        let stub = Stub { _ in .json(status: 200, body: "{}") }
        let (client, store) = makeClient(stub)
        var events = client.sessionEvents.makeAsyncIterator()

        #expect(await client.sessionRejected(token: "someone-elses-token") == false)
        #expect(try store.load()?.token == "session-token")

        #expect(await client.sessionRejected(token: "session-token"))
        #expect(try store.load() == nil)
        #expect(await events.next() == .sessionEnded)
    }

    @Test func forbiddenIsNotASessionEnding() async throws {
        let stub = Stub { _ in .json(status: 403, body: "{}") }
        let (client, store) = makeClient(stub)

        await #expect(throws: AudienceKitError.forbidden) { try await client.venues() }
        #expect(try store.load()?.token == "session-token")
    }

    @Test func anOutdatedSDKIsToldToUpdate() async throws {
        let stub = Stub { _ in
            .json(status: 426, body: #"{"error":"update_required","platform":"ios","minimum_sdk_version":"0.3.0","message":"This version of the app is out of date."}"#)
        }
        let (client, store) = makeClient(stub)

        await #expect(throws: AudienceKitError.updateRequired(minimumSDKVersion: "0.3.0", message: "This version of the app is out of date.")) {
            try await client.venues()
        }
        #expect(try store.load()?.token == "session-token")
        #expect(stub.requests.last?.header("X-AudienceKit-Client") == "AudienceKit-Swift/\(AudienceKitSDK.version)")
    }

    @Test func anUpdateIsRequiredEvenWithoutABody() async throws {
        let stub = Stub { _ in .json(status: 426, body: "") }
        let (client, _) = makeClient(stub)

        await #expect(throws: AudienceKitError.updateRequired(minimumSDKVersion: "", message: nil)) { try await client.venues() }
        #expect(AudienceKitError.updateRequired(minimumSDKVersion: "", message: nil).errorDescription?.isEmpty == false)
    }

    @Test func signInIsToldToUpdateToo() async throws {
        let stub = Stub { _ in .json(status: 426, body: #"{"error":"update_required","minimum_sdk_version":"1.0"}"#) }
        let (client, _) = makeClient(stub, token: nil)

        await #expect(throws: AudienceKitError.updateRequired(minimumSDKVersion: "1.0", message: nil)) {
            try await client.signIn(facebookAccessToken: "fb", device: device)
        }
    }

    @Test func anUnsupportedAPIVersionIsReported() async throws {
        let stub = Stub { _ in .json(status: 400, body: #"{"error":"unsupported_api_version","supported":[]}"#) }
        let (client, store) = makeClient(stub)

        do {
            _ = try await client.venues()
            Issue.record("expected an error")
        } catch let error as AudienceKitError {
            #expect(error.code == AudienceKitError.Code.unsupportedAPIVersion)
        }
        #expect(try store.load()?.token == "session-token")
    }

    @Test func mapsRESTStatusesToCodes() async throws {
        let stub = Stub { request in
            switch request.path {
            case "/v1/a": .json(status: 409, body: #"{"error":"conflict","message":"Already paid"}"#)
            case "/v1/b": .json(status: 429, body: "")
            case "/v1/c": .json(status: 503, body: "")
            default: .json(status: 418, body: #"{"error":"teapot"}"#)
            }
        }
        let (client, _) = makeClient(stub)

        for (path, code, status) in [("/v1/a", AudienceKitError.Code.conflict, 409),
                                     ("/v1/b", AudienceKitError.Code.rateLimited, 429),
                                     ("/v1/c", AudienceKitError.Code.internalError, 503),
                                     ("/v1/d", "TEAPOT", 418)] {
            do {
                _ = try await client.data(for: APIRequest(path: path))
                Issue.record("expected an error for \(path)")
            } catch let error as AudienceKitError {
                #expect(error.code == code)
                #expect(error.status == status)
            }
        }
    }

    @Test func requiresASession() async throws {
        let stub = Stub { _ in .json(status: 200, body: "{}") }
        let (client, _) = makeClient(stub, token: nil)

        await #expect(throws: AudienceKitError.notSignedIn) { try await client.venues() }
        #expect(stub.requests.isEmpty)
    }

    @Test func reportsNetworkFailures() async throws {
        let stub = Stub { _ in .failure(URLError(.notConnectedToInternet)) }
        let (client, _) = makeClient(stub)

        do {
            _ = try await client.venues()
            Issue.record("expected an error")
        } catch let error as AudienceKitError {
            #expect(error.code == AudienceKitError.Code.network)
            #expect(error.underlying?.code == .notConnectedToInternet)
        }
    }

    @Test func reportsMalformedResponses() async throws {
        let stub = Stub { _ in .json(status: 200, body: #"{"data":{"venues":"nope"}}"#) }
        let (client, _) = makeClient(stub)

        do {
            _ = try await client.venues()
            Issue.record("expected an error")
        } catch let error as AudienceKitError {
            #expect(error.code == AudienceKitError.Code.decoding)
        }
    }
}

@Suite struct MobileOperations {
    @Test func findsTheClosestLocale() async throws {
        let stub = Stub { _ in
            .json(status: 200, body: #"{"data":{"closestLocale":{"id":"l-1","name":"Seattle","label":"SEA"}}}"#)
        }
        let (client, _) = makeClient(stub)

        let locale = try await client.closestLocale(near: Coordinate(latitude: 47.6, longitude: -122.3), beaconMajor: 0)

        #expect(locale?.name == "Seattle")
        let body = try #require(stub.requests.first).jsonBody()
        let near = try #require((body["variables"] as? [String: Any])?["near"] as? [String: Any])
        #expect(near["latitude"] as? Double == 47.6)
        #expect(near["longitude"] as? Double == -122.3)
        #expect(near["beaconMajor"] == nil)

        let withBeacon = Coordinate(latitude: 1, longitude: 2).coordinatesInput(beaconMajor: 7, beaconMinor: 0)
        #expect(withBeacon == ["latitude": 1.0, "longitude": 2.0, "beaconMajor": 7])
        #expect(Coordinate(latitude: 1, longitude: 2).graphQLValue == ["latitude": 1.0, "longitude": 2.0])
    }

    @Test func setsAnRSVP() async throws {
        let stub = Stub { _ in
            .json(status: 200, body: #"{"data":{"rsvpEvent":{"event":{"id":"e-1","rsvp":{"mine":"ATTENDING"}}}}}"#)
        }
        let (client, _) = makeClient(stub)

        let state = try await client.setRSVP(.attending, forEvent: "e-1")

        #expect(state == .attending)
        let body = try #require(stub.requests.first).jsonBody()
        let variables = try #require(body["variables"] as? [String: Any])
        #expect(variables["eventId"] as? String == "e-1")
        #expect(variables["state"] as? String == "ATTENDING")
        #expect((body["query"] as? String)?.contains("rsvp { mine }") == true)
        #expect((body["query"] as? String)?.contains("viewerRsvp") == false)
    }

    @Test func registersTheDevice() async throws {
        let stub = Stub { _ in .json(status: 200, body: #"{"data":{"registerDevice":{"registered":true}}}"#) }
        let (client, _) = makeClient(stub)

        try await client.registerDevice(token: "apns", appId: "social.hotmess.ios", sandbox: true)
        try await client.registerDevice(token: "apns")

        let body = try #require(stub.requests.first).jsonBody()
        #expect(body["operationName"] as? String == "RegisterDevice")
        let variables = try #require(body["variables"] as? [String: Any])
        #expect(variables["notificationToken"] as? String == "apns")
        #expect(variables["appId"] as? String == "social.hotmess.ios")
        #expect(variables["sandbox"] as? Bool == true)
        #expect((body["query"] as? String)?.contains("appId: $appId, sandbox: $sandbox") == true)
        // Left out, not sent as null.
        let bare = try #require(stub.requests.last).jsonBody()["variables"] as? [String: Any]
        #expect(bare?.keys.sorted() == ["notificationToken"])
    }

    @Test func decodesWithTheCallersDecoder() async throws {
        struct Payload: Decodable, Sendable { var when: Date }
        let stub = Stub { _ in .json(status: 200, body: #"{"data":{"when":"2026-10-06T20:00:00Z"}}"#) }
        let (client, _) = makeClient(stub)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // Aliases, so the document is one the schema knows while the stub answers what the decoder is given.
        let payload = try await client.graphQL("{ when: name }", as: Payload.self, decoder: decoder)

        #expect(payload.when == Date(timeIntervalSince1970: 1_791_316_800))
    }

    @Test func decodesISO8601DatesByDefault() async throws {
        struct Payload: Decodable, Sendable { var when: Date; var later: Date }
        let stub = Stub { _ in
            .json(status: 200, body: #"{"data":{"when":"2026-10-06T20:00:00.500Z","later":"2026-10-06T13:00:00-07:00"}}"#)
        }
        let (client, _) = makeClient(stub)

        let payload = try await client.graphQL("{ when: name later: subdomain }", as: Payload.self)

        #expect(payload.when == Date(timeIntervalSince1970: 1_791_316_800.5))
        #expect(payload.later == Date(timeIntervalSince1970: 1_791_316_800))
        #expect(ISO8601.string(from: payload.later) == "2026-10-06T20:00:00Z")
        #expect(ISO8601.string(from: payload.when) == "2026-10-06T20:00:00.500Z")
        #expect(ISO8601.date(from: ISO8601.string(from: payload.when)) == payload.when)
        #expect(ISO8601.date(from: "yesterday") == nil)
        #expect(String(decoding: try JSONEncoder.audienceKit.encode([payload.later]), as: UTF8.self)
            == #"["2026-10-06T20:00:00Z"]"#)
    }
}

@Suite struct AudienceResolution {
    @Test func usesTheCredentialsAudience() async throws {
        let stub = Stub { _ in .json(status: 200, body: #"{"data":{"venues":{"list":{"nodes":[]}}}}"#) }
        let (client, _) = makeClient(stub, audienceID: nil, credentialAudienceID: "from-credential")

        _ = try await client.venues()

        #expect(stub.requests.map(\.path) == ["/v1/audience/from-credential/graphql"])
        #expect(try await client.audienceID() == "from-credential")
    }

    @Test func looksUpTheHostsAudienceForAPlatformSession() async throws {
        let stub = Stub { request in
            if request.path == "/v1/branding" {
                return .json(status: 200, body: #"""
                {"audience":{"id":"from-branding","name":"Hot Mess","subdomain":"hotmess"},
                 "facebook_app_id":"100000000000002","theme":{"preset":"hot_mess","tagline":null,"light":{},"dark":{}}}
                """#)
            }
            return .json(status: 200, body: #"{"data":{"venues":{"list":{"nodes":[]}}}}"#)
        }
        // A platform-console session belongs to no audience.
        let (client, _) = makeClient(stub, audienceID: nil, credentialAudienceID: nil)

        _ = try await client.venues()
        _ = try await client.venues()

        #expect(stub.requests.map(\.path) == [
            "/v1/branding", "/v1/audience/from-branding/graphql", "/v1/audience/from-branding/graphql",
        ])
    }

    @Test func needsAnAudienceOrAHost() async throws {
        let stub = Stub { _ in .json(status: 200, body: "{}") }
        let (client, _) = makeClient(stub, host: nil, audienceID: nil, credentialAudienceID: nil)

        await #expect(throws: AudienceKitError.missingConfiguration("set an audienceID or a host")) {
            try await client.venues()
        }
        #expect(stub.requests.isEmpty)
    }
}

@Suite struct Cover {
    static let admission = #"""
    {"id":"7d9f2c1e-3b4a-4e5f-8a6b-1c2d3e4f5a6b","status":"PENDING","night":"2026-10-09",
     "amount":{"cents":1000,"currency":"usd"},"total":{"cents":1112,"currency":"usd"},
     "isRefundable":false,"passSecret":"c2VjcmV0LWtleS1mb3ItaG90LW1lc3MtY292ZXI=",
     "scanCount":1,"checkedInAt":"2026-10-10T04:41:00.500Z","profile":{"id":"u-1","name":"Rick Mark","avatarUrl":null},
     "venue":{"id":"v-1","name":"The Stud","photoUrl":null},"event":null}
    """#

    @Test func buysAndConfirmsCover() async throws {
        let stub = Stub { request in
            let operation = (try? request.jsonBody()["operationName"] as? String) ?? ""
            if operation == "BuyCover" {
                return .json(status: 200, body: #"{"data":{"buyCover":{"admission":\#(Self.admission),"#
                    + #""provider":"STRIPE","paymentIntentClientSecret":"pi_1_secret_2","publishableKey":"pk_test_1","#
                    + #""stripeAccountId":"acct_1"}}}"#)
            }
            let paid = Self.admission.replacingOccurrences(of: "PENDING", with: "PAID")
            return .json(status: 200, body: #"{"data":{"confirmCover":{"admission":\#(paid)}}}"#)
        }
        let (client, _) = makeClient(stub)

        let purchase = try await client.buyCover(venueID: "v-1")
        #expect(purchase.paymentIntentClientSecret == "pi_1_secret_2")
        #expect(purchase.stripeAccountId == "acct_1")
        #expect(purchase.admission.status == .pending)
        #expect(purchase.admission.total == Money(cents: 1112, currency: "usd"))
        #expect(purchase.admission.amount.cents == 1000)
        #expect(purchase.admission.profile.name == "Rick Mark")
        #expect(purchase.admission.venue.name == "The Stud")
        #expect(purchase.admission.checkedInAt == Date(timeIntervalSince1970: 1_791_607_260.5))
        #expect(try #require(stub.requests.first).jsonBody()["variables"] as? [String: String] == ["venueId": "v-1"])

        let admission = try await client.confirmCover(admissionID: purchase.admission.id)
        #expect(admission.status == .paid)
        #expect(try #require(stub.requests.last).jsonBody()["variables"] as? [String: String]
            == ["admissionId": "7d9f2c1e-3b4a-4e5f-8a6b-1c2d3e4f5a6b"])
    }

    @Test func paysSquareCoverWithAToken() async throws {
        let stub = Stub { request in
            let operation = (try? request.jsonBody()["operationName"] as? String) ?? ""
            if operation == "BuyCover" {
                return .json(status: 200, body: #"{"data":{"buyCover":{"admission":\#(Self.admission),"#
                    + #""provider":"SQUARE","paymentIntentClientSecret":null,"publishableKey":null,"#
                    + #""stripeAccountId":null,"squareApplicationId":"sq0idp-1","squareLocationId":"L1"}}}"#)
            }
            let paid = Self.admission.replacingOccurrences(of: "PENDING", with: "PAID")
            return .json(status: 200, body: #"{"data":{"payCover":{"admission":\#(paid)}}}"#)
        }
        let (client, _) = makeClient(stub)

        let purchase = try await client.buyCover(venueID: "v-1")
        #expect(purchase.isSquare)
        #expect(purchase.squareApplicationId == "sq0idp-1")
        #expect(purchase.squareLocationId == "L1")

        let admission = try await client.payCover(admissionID: purchase.admission.id, sourceID: "cnon:ok")
        #expect(admission.status == .paid)
        #expect(try #require(stub.requests.last).jsonBody()["variables"] as? [String: String]
            == ["admissionId": "7d9f2c1e-3b4a-4e5f-8a6b-1c2d3e4f5a6b", "sourceId": "cnon:ok"])
    }

    @Test func decodesScansAndDoors() async throws {
        let stub = Stub { request in
            let operation = (try? request.jsonBody()["operationName"] as? String) ?? ""
            if operation == "DoorVenues" {
                return .json(status: 200, body: #"""
                {"data":{"me":{"cover":{"doorVenues":{"nodes":[{"id":"v-1","name":"The Stud","photoUrl":null,
                  "tickets":{"cover":{"door":{"night":"2026-10-09","paidCount":12,"checkedInCount":8,
                  "gross":{"cents":12000,"currency":"usd"}}}}}]}}}}}
                """#)
            }
            return .json(status: 200, body: #"""
            {"data":{"scanAdmission":{"result":{"outcome":"RE_ENTRY","message":"Re-entry · Rick, in at 9:41pm",
              "admission":null}}}}
            """#)
        }
        let (client, _) = makeClient(stub)

        let venues = try await client.doorVenues()
        #expect(venues.first?.door?.paidCount == 12)
        #expect(venues.first?.door?.checkedInCount == 8)
        #expect(venues.first?.door?.gross == Money(cents: 12000, currency: "usd"))

        let result = try await client.scanAdmission(venueID: "v-1", code: "HMC1.a.1.b")
        #expect(result.outcome == .reEntry)
        #expect(result.message.hasPrefix("Re-entry"))
        #expect(try #require(stub.requests.last).jsonBody()["variables"] as? [String: String]
            == ["venueId": "v-1", "code": "HMC1.a.1.b"])
        // Working the door is staff work: both go to the audience's staff endpoint.
        #expect(stub.requests.map(\.path) == ["/v1/audience/\(audienceID)/staffql", "/v1/audience/\(audienceID)/staffql"])
    }

    @Test func decodesAVenuesCoverMixin() async throws {
        let stub = Stub { request in
            let id = (try? request.jsonBody()["variables"] as? [String: String])?["id"]
            if id == "v-2" {
                // A venue that takes no cover tonight has no charge.
                return .json(status: 200, body: #"{"data":{"venues":{"venue":{"id":"v-2","name":"Free Bar","tickets":{"cover":{"charge":null,"viewerAdmission":null}}}}}}"#)
            }
            return .json(status: 200, body: #"""
            {"data":{"venues":{"venue":{"id":"v-1","name":"The Stud","tickets":{"cover":{
              "charge":{"amount":{"cents":1000,"currency":"usd"},"fee":{"cents":112,"currency":"usd"},
                "total":{"cents":1112,"currency":"usd"},"night":"2026-10-09","from":"21:00","payable":true,"event":null},
              "viewerAdmission":\#(Self.admission)}}}}}}
            """#)
        }
        let (client, _) = makeClient(stub)

        let coverResponse = try await client.venueCover(venueID: "v-1")
        let cover = try #require(coverResponse)
        #expect(cover.coverCharge?.total.cents == 1112)
        #expect(cover.coverCharge?.fee == Money(cents: 112, currency: "usd"))
        #expect(cover.coverCharge?.payable == true)
        #expect(cover.viewerAdmission?.status == .pending)
        #expect(try JSONDecoder().decode(VenueCover.self, from: JSONEncoder().encode(cover)) == cover)

        let freeResponse = try await client.venueCover(venueID: "v-2")
        let free = try #require(freeResponse)
        #expect(free.coverCharge == nil)
        #expect(free.viewerAdmission == nil)
    }

    @Test func toleratesNewStatusesAndOutcomes() throws {
        let decoded = try JSONDecoder().decode([AdmissionStatus].self, from: Data(#"["PAID","ON_HOLD"]"#.utf8))
        #expect(decoded == [.paid, .unknown])
        #expect(try JSONDecoder().decode([ScanOutcome].self, from: Data(#"["BANNED"]"#.utf8)) == [.unknown])
    }

    #if canImport(CryptoKit)
    /// Vectors from the API's CoverPass (Ruby, OpenSSL::HMAC) for the same secret, admission and time.
    @Test func makesTheSameCodeAsTheAPI() {
        let id = "7d9f2c1e-3b4a-4e5f-8a6b-1c2d3e4f5a6b"
        let secret = "c2VjcmV0LWtleS1mb3ItaG90LW1lc3MtY292ZXI="
        let start = Date(timeIntervalSince1970: 1_791_331_200)

        #expect(CoverPass.window(at: start) == 59_711_040)
        #expect(CoverPass.code(admissionID: id, secret: secret, at: start)
            == "HMC1.7d9f2c1e-3b4a-4e5f-8a6b-1c2d3e4f5a6b.59711040.HOStwur5mLjF7zvb")
        // Same window until 30 seconds pass; the next one's signature is URL-safe.
        #expect(CoverPass.code(admissionID: id, secret: secret, at: start.addingTimeInterval(29.9))
            == "HMC1.7d9f2c1e-3b4a-4e5f-8a6b-1c2d3e4f5a6b.59711040.HOStwur5mLjF7zvb")
        #expect(CoverPass.code(admissionID: id, secret: secret, at: start.addingTimeInterval(30))
            == "HMC1.7d9f2c1e-3b4a-4e5f-8a6b-1c2d3e4f5a6b.59711041.p2tYO-g5T45lRFzN")
        #expect(CoverPass.secondsRemaining(at: start.addingTimeInterval(12)) == 18)
        #expect(CoverPass.code(admissionID: id, secret: "not base64!", at: start) == nil)
        // The prefix is the audience's: the configuration's by default, HMC1 unless set.
        #expect(CoverPass.code(admissionID: id, secret: secret, prefix: "XYZ1", at: start)
            == "XYZ1.7d9f2c1e-3b4a-4e5f-8a6b-1c2d3e4f5a6b.59711040.HOStwur5mLjF7zvb")
        #expect(AudienceKitConfiguration(baseURL: URL(string: "https://api.example")!).coverPassPrefix == "HMC1")
        let configuration = AudienceKitConfiguration(baseURL: URL(string: "https://api.example")!,
                                                     coverPassPrefix: "XYZ1", feeLabel: "Hot Mess fee")
        let client = AudienceKitClient(configuration: configuration)
        let usd = Money(cents: 1000, currency: "usd")
        let buyer = Profile(id: "u-1", name: "Rick M.")
        let admission = Admission(id: id, status: .paid, night: "2026-10-09", amount: usd, total: usd,
                                  passSecret: secret, profile: buyer, venue: CoverVenue(id: "v-1"))
        #expect(client.coverPassCode(for: admission, at: start)?.hasPrefix("XYZ1.") == true)
        let withoutSecret = Admission(id: id, status: .paid, night: "2026-10-09", amount: usd, total: usd,
                                      profile: buyer, venue: CoverVenue(id: "v-1"))
        #expect(client.coverPassCode(for: withoutSecret, at: start) == nil)
        #expect(configuration.feeLabel == "Hot Mess fee")
    }
    #endif
}

@Suite struct BrandingTests {
    @Test func fetchesBrandingWithoutASession() async throws {
        let stub = Stub { _ in
            .json(status: 200, body: #"""
            {"audience":{"id":"a-1","name":"Hot Mess","subdomain":"hotmess"},
             "facebook_app_id":"100000000000002","facebook_login_config_id":"200000000000001",
             "theme":{"preset":"hot_mess","tagline":"Queer nights out","light":{"accent":"#9c1c62"},"dark":{}}}
            """#)
        }
        let (client, _) = makeClient(stub, token: nil)

        let branding = try await client.branding()

        let request = try #require(stub.requests.first)
        #expect(request.method == "GET")
        #expect(request.url.query == "host=hotmess.admin.audiencekit.com")
        #expect(request.header("Authorization") == nil)

        #expect(branding.audience.name == "Hot Mess")
        #expect(branding.facebookAppID == "100000000000002")
        #expect(branding.facebookLoginConfigID == "200000000000001")
        #expect(branding.theme.preset == "hot_mess")
        #expect(branding.theme.color("accent") == RGBAColor(hex: "#9c1c62"))
        #expect(branding.theme.color("accent", dark: true) == RGBAColor(hex: "#9c1c62"))
        #expect(branding.theme.color("missing") == nil)
    }

    @Test func anUnknownHostIsNotFound() async throws {
        let stub = Stub { _ in .json(status: 404, body: "{}") }
        let (client, _) = makeClient(stub, token: nil)

        await #expect(throws: AudienceKitError.notFound) { try await client.branding(host: "nobody.example") }
    }

    @Test func toleratesAMissingTheme() throws {
        let json = #"{"audience":{"id":"a","name":"A","subdomain":"a"},"facebook_app_id":null,"theme":{}}"#
        let branding = try JSONDecoder().decode(Branding.self, from: Data(json.utf8))
        #expect(branding.theme.preset == "default")
        #expect(branding.theme.light.isEmpty)
    }
}

@Suite struct Values {
    @Test func decodesPresenceLeniently() throws {
        let json = #"[{"id":"f-1","presence":"ONLINE"},{"id":"f-2","presence":"online"},{"id":"f-3","presence":"AWAY"},{"id":"f-4"}]"#
        let friends = try JSONDecoder().decode([Friend].self, from: Data(json.utf8))
        #expect(friends.map(\.presence) == [.online, .online, .unknown("AWAY"), nil])
        #expect(friends[2].presence?.isReachable == false)
        #expect(Presence.known.contains(.offline))
    }

    @Test func keepsUnknownEnumValuesAndSendsThemBack() throws {
        let states = try JSONDecoder().decode([RSVPState].self, from: Data(#"["ATTENDING","PLUS_ONE"]"#.utf8))
        #expect(states == [.attending, .unknown("PLUS_ONE")])
        #expect(states.map(\.rawValue) == ["ATTENDING", "PLUS_ONE"])
        #expect(String(decoding: try JSONEncoder().encode(states), as: UTF8.self) == #"["ATTENDING","PLUS_ONE"]"#)
        #expect(!RSVPState.known.contains(.unknown("PLUS_ONE")))

        let relationship = try JSONDecoder().decode([PersonEventInvolvement.Relationship].self,
                                                    from: Data(#"["troupe","GUEST"]"#.utf8))
        #expect(relationship == [.troupe, .unknown("GUEST")])

        let providers = try JSONDecoder().decode([PaymentProvider].self, from: Data(#"["SQUARE","ADYEN"]"#.utf8))
        #expect(providers == [.square, .unknown("ADYEN")])

        #expect(AudienceKitEnvironment(rawValue: "staging") == .staging)
        #expect(AudienceKitEnvironment(rawValue: "preview") == .unknown("preview"))
        #expect(AudienceKitEnvironment.unknown("preview").rawValue == "preview")
        #expect(AudienceKitEnvironment.known == [.production, .staging])
    }

    @Test func parsesHexColors() {
        #expect(RGBAColor(hex: "#ff0000") == RGBAColor(red: 1, green: 0, blue: 0))
        #expect(RGBAColor(hex: "0f0") == RGBAColor(red: 0, green: 1, blue: 0))
        #expect(RGBAColor(hex: "#0000ff80")?.alpha == Double(0x80) / 255)
        #expect(RGBAColor(hex: "nope") == nil)
    }

    @Test func carriesDesignTokens() {
        #expect(DesignTokens.hotMess.accent == RGBAColor(hex: "#b8236f"))
        #expect(DesignTokens.hotMessDark.accent == RGBAColor(hex: "#ff7ab6"))
        #expect(DesignTokens.presets["hot_mess"]?.dark == DesignTokens.hotMessDark)
        #expect(DesignTokens.presets["default"]?.light == DesignTokens.light)
        #expect(DesignTokens.hotMess.glass.alpha == Double(140) / 255)
        #expect(DesignTokens.Spacing.s4 == 16)
    }

    @Test func parsesWKTPoints() {
        #expect(Coordinate(latitude: 37.25, longitude: -122.5).wkt == "POINT (-122.5 37.25)")
        #expect(Coordinate(wkt: "POINT (-122.5 37.25)") == Coordinate(latitude: 37.25, longitude: -122.5))
        #expect(Coordinate(wkt: "SRID=4326;POINT(1 2)") == Coordinate(latitude: 2, longitude: 1))
        #expect(Coordinate(wkt: "POLYGON ((0 0, 1 1))") == nil)
        #expect(Coordinate(wkt: "") == nil)
    }

    @Test func inMemoryStoreRoundTrips() throws {
        let credential = Credential(token: "t", userId: "u-1", audienceId: "a-1", role: "member",
                                    endpoint: URL(string: "https://api.example/v1/audience/a-1/graphql")!)
        let store = InMemoryCredentialStore()
        #expect(try store.load() == nil)
        try store.save(credential)
        #expect(try store.load() == credential)
        try store.delete()
        #expect(try store.load() == nil)
    }
}

@Suite struct Credentials {
    @Test func decodesTheTokenJSON() throws {
        let json = #"""
        {"token":"jwt","userId":"u-1","audienceId":"a-1","role":"venue_device",
         "endpoint":"https://api.audiencekit.com/v1/audience/a-1/staffql","venueDeviceId":"vd-1",
         "expiresAt":"2026-10-12T03:00:00.250Z"}
        """#
        let credential = try JSONDecoder().decode(Credential.self, from: Data(json.utf8))

        #expect(credential.token == "jwt")
        #expect(credential.userId == "u-1")
        #expect(credential.audienceId == "a-1")
        #expect(credential.role == "venue_device")
        #expect(credential.venueDeviceId == "vd-1")
        #expect(credential.isStaff)
        #expect(credential.origin == URL(string: "https://api.audiencekit.com"))
        #expect(credential.expiresAt == Date(timeIntervalSince1970: 1_791_774_000.25))
        #expect(credential.isExpired(at: Date(timeIntervalSince1970: 1_791_774_001)))
        #expect(!credential.isExpired(at: Date(timeIntervalSince1970: 1_791_774_000)))
        // Not in the API's JSON: the SDK stamps the version it spoke when the credential was issued.
        #expect(credential.apiVersion == AudienceKitSDK.apiVersion)
    }

    @Test func toleratesAPlatformSession() throws {
        let json = #"""
        {"token":"jwt","userId":"u-1","audienceId":null,"role":"admin",
         "endpoint":"http://localhost:3000/v1/tenants/graphql","venueDeviceId":null,"expiresAt":null}
        """#
        let credential = try JSONDecoder().decode(Credential.self, from: Data(json.utf8))
        #expect(credential.audienceId == nil)
        #expect(credential.expiresAt == nil)
        #expect(!credential.isExpired())
        #expect(!credential.isStaff)
        #expect(credential.origin == URL(string: "http://localhost:3000"))
    }

    @Test func roundTripsThroughTheStoreFormat() throws {
        let credential = Credential(token: "t", userId: "u-1", audienceId: "a-1", role: "member",
                                    endpoint: URL(string: "https://api.example/v1/audience/a-1/graphql")!,
                                    expiresAt: Date(timeIntervalSince1970: 1_791_774_000), apiVersion: "2026-10-11")

        let data = try CredentialEnvelope.encode(credential)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["v"] as? Int == CredentialEnvelope.formatVersion)
        #expect((object?["credential"] as? [String: Any])?["expiresAt"] as? String == "2026-10-12T03:00:00Z")
        #expect(CredentialEnvelope.decode(data) == credential)

        // A raw token from the first SDKs' keychain item, or another format version, reads as no credential.
        #expect(CredentialEnvelope.decode(Data("eyJhbGciOiJIUzI1NiJ9.e30.sig".utf8)) == nil)
        #expect(CredentialEnvelope.decode(Data(#"{"v":0,"credential":{}}"#.utf8)) == nil)
    }
}
