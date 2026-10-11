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

private func makeClient(
    _ stub: Stub,
    host: String? = "hotmess.admin.audiencekit.com",
    audienceID: String? = audienceID,
    token: String? = "session-token",
    environment: AudienceKitEnvironment = .production
) -> (AudienceKitClient, InMemoryTokenStore) {
    let store = InMemoryTokenStore(token: token)
    let configuration = AudienceKitConfiguration(baseURL: stub.baseURL, host: host, audienceID: audienceID,
                                                 facebookAppID: "100000000000001", environment: environment)
    return (AudienceKitClient(configuration: configuration, tokenStore: store, session: stub.session), store)
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
    @Test func exchangesTheFacebookTokenAndStoresTheSession() async throws {
        let stub = Stub { _ in
            .json(status: 200, body: #"{"token":"jwt-1","access_token":"jwt-1","user":{"id":"u-1","name":"Rick"}}"#)
        }
        let (client, store) = makeClient(stub, token: nil)
        var events = client.sessionEvents.makeAsyncIterator()

        let result = try await client.signIn(facebookAccessToken: "fb-token", device: device)

        #expect(result.token == "jwt-1")
        #expect(result.user == .init(id: "u-1", name: "Rick"))
        #expect(try store.loadToken() == "jwt-1")
        #expect(await client.isSignedIn)
        #expect(await events.next() == .signedIn)

        let request = try #require(stub.requests.first)
        #expect(request.method == "POST")
        #expect(request.path == "/v1/token")
        #expect(request.header("Authorization") == nil)
        #expect(request.header("Content-Type") == "application/json")
        #expect(request.header("X-AudienceKit-Environment") == nil)

        let body = try request.jsonBody()
        #expect(body["facebook_token"] as? String == "fb-token")
        #expect(body["host"] as? String == "hotmess.admin.audiencekit.com")
        #expect(body["facebook_app_id"] as? String == "100000000000001")

        let sentDevice = try #require(body["device"] as? [String: String])
        #expect(sentDevice == ["identifier": "device-1", "type": "apple", "model": "iPhone17,1",
                               "version": "2.0", "build": "42"])
    }

    @Test func stagingBuildsSayTheyAreStaging() async throws {
        let stub = Stub { _ in
            .json(status: 200, body: #"{"token":"jwt-1","access_token":"jwt-1","user":{"id":"u-1","name":"Rick"}}"#)
        }
        let (client, _) = makeClient(stub, token: nil, environment: .staging)

        _ = try await client.signIn(facebookAccessToken: "fb-token", device: device)

        #expect(try #require(stub.requests.first).header("X-AudienceKit-Environment") == "staging")
    }

    @Test func leavesOutTheHostWhenNoneIsConfigured() async throws {
        let stub = Stub { _ in .json(status: 200, body: #"{"token":"jwt-1","user":{"id":"u-1","name":null}}"#) }
        let (client, _) = makeClient(stub, host: nil, token: nil)

        try await client.signIn(facebookAccessToken: "fb-token", device: device)

        let body = try #require(stub.requests.first).jsonBody()
        #expect(body["host"] == nil)
    }

    @Test func exchangesAnOAuthCode() async throws {
        let stub = Stub { _ in .json(status: 200, body: #"{"token":"jwt-2","user":{"id":"u-1","name":"Rick"}}"#) }
        let (client, store) = makeClient(stub, token: nil)

        try await client.signIn(facebookCode: "code-1", redirectURI: "fb123://authorize/", device: device)

        let body = try #require(stub.requests.first).jsonBody()
        #expect(body["code"] as? String == "code-1")
        #expect(body["redirect_uri"] as? String == "fb123://authorize/")
        #expect(body["facebook_token"] == nil)
        #expect(body["host"] as? String == "hotmess.admin.audiencekit.com")
        #expect(try store.loadToken() == "jwt-2")
    }

    @Test func signsInWithApple() async throws {
        let stub = Stub { _ in .json(status: 200, body: #"{"token":"jwt-3","user":{"id":"u-2","name":"Ada Byron"}}"#) }
        let (client, store) = makeClient(stub, token: nil)

        let result = try await client.signIn(appleIdentityToken: "apple-jwt", firstName: "Ada", lastName: "Byron",
                                             device: device)

        #expect(result.user == .init(id: "u-2", name: "Ada Byron"))
        #expect(try store.loadToken() == "jwt-3")
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
        let stub = Stub { _ in .json(status: 200, body: #"{"token":"jwt-4","user":{"id":"u-2","name":"Ada Byron"}}"#) }
        let (client, store) = makeClient(stub, token: "jwt-3")

        try await client.connectFacebook(code: "code-1", redirectURI: "fb123://authorize/", device: device)

        let request = try #require(stub.requests.first)
        #expect(request.path == "/v1/token")
        #expect(request.header("Authorization") == "JWT jwt-3")
        let body = try request.jsonBody()
        #expect(body["connect"] as? Bool == true)
        #expect(body["code"] as? String == "code-1")
        #expect(try store.loadToken() == "jwt-4")
    }

    @Test func aRejectedFacebookTokenIsNotASessionEnding() async throws {
        let stub = Stub { _ in .json(status: 401, body: "{}") }
        let (client, store) = makeClient(stub, token: nil)

        await #expect(throws: AudienceKitError.signInRejected) {
            try await client.signIn(facebookAccessToken: "bad", device: device)
        }
        #expect(try store.loadToken() == nil)
    }

    @Test func surfacesTheFaultMessage() async throws {
        let stub = Stub { _ in .json(status: 400, body: #"{"fault":{"message":"Facebook token invalid"}}"#) }
        let (client, _) = makeClient(stub, token: nil)

        await #expect(throws: AudienceKitError.signInFailed(message: "Facebook token invalid")) {
            try await client.signIn(facebookAccessToken: "bad", device: device)
        }
    }

    @Test func signOutForgetsTheToken() async throws {
        let stub = Stub { _ in .json(status: 200, body: "{}") }
        let (client, store) = makeClient(stub)
        var events = client.sessionEvents.makeAsyncIterator()

        await client.signOut()

        #expect(try store.loadToken() == nil)
        #expect(await events.next() == .signedOut)
    }
}

@Suite struct GraphQL {
    static let venuesResponse = #"""
    {"data":{"venues":[{
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
    }]}}
    """#

    @Test func sendsTheSessionTokenToTheAudienceEndpoint() async throws {
        let stub = Stub { _ in .json(status: 200, body: Self.venuesResponse) }
        let (client, _) = makeClient(stub)

        let venues = try await client.venues()

        let request = try #require(stub.requests.first)
        #expect(request.method == "POST")
        #expect(request.path == "/v1/audience/\(audienceID)/graphql")
        #expect(request.header("Authorization") == "JWT session-token")

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

        // Encoding writes the profile facet back, so a venue round-trips.
        #expect(try JSONDecoder().decode(Venue.self, from: JSONEncoder().encode(venue)) == venue)
        #expect(try JSONDecoder().decode(Venue.self, from: JSONEncoder().encode(pageless)) == pageless)

        #expect(venue.tags == nil)
        #expect(pageless.tags?.map(\.name) == ["Leather"])
        #expect(pageless.tags?.first?.color == "#222222")
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
                {"data":{"people":[{"id":"pe-1","order":1,"global":false,"likeRequired":true,
                  "profile":{"facebook":{"page":{"id":"p-2","name":"DJ Example","photoUrl":null,"bannerUrl":null}}},
                  "locales":[{"id":"l-2","name":"Portland"}]},
                  {"id":"pe-2","name":"DJ Nobody","order":2,"global":false,"likeRequired":false,
                  "profile":{"facebook":{"page":null}},
                  "venues":{"home":{"id":"v-1","name":"Neighbours","photoUrl":null,"locale":{"id":"l-1","name":"Seattle"},
                    "friends":[{"id":"f-1","name":"Sam Okafor","facebookId":"123","presence":"ONLINE"}]}},
                  "events":{"involvements":{"edges":[
                    {"relationship":"TROUPE","role":"performer","via":{"id":"pe-9","name":"Those Bitches"},
                     "node":{"id":"e-1","name":"Drag Brunch","startAt":"2026-10-09T21:00:00-07:00",
                       "locale":{"id":"l-1","name":"Seattle"},
                       "venue":{"name":"Neighbours","venue":{"id":"v-1","name":"Neighbours","photoUrl":null}}}},
                    null,
                    {"relationship":"DIRECT","role":"host","via":null,
                     "node":{"id":"e-2","name":"Bingo","startAt":"2026-10-10T19:00:00-07:00",
                       "venue":{"name":"To be announced","venue":null}}}]}}}]}}
                """#)
            case "Me":
                return .json(status: 200, body: #"""
                {"data":{"me":{"id":"u-1","name":"Rick Mark","firstName":"Rick","lastName":"Mark",
                  "emailAddress":null,"isAdmin":true,"presence":"PUSH"}}}
                """#)
            default:
                return .json(status: 200, body: #"""
                {"data":{"audience":{"id":"a-1","name":"Hot Mess","subdomain":"hotmess",
                  "theme":{"preset":"hot_mess","tagline":"Queer nights out","light":[{"name":"accent","value":"#9c1c62"}],"dark":[]}}}}
                """#)
            }
        }
        let (client, _) = makeClient(stub)

        let people = try await client.people()
        // Talent added by name has no Facebook Page yet.
        #expect(people.map(\.name) == ["DJ Example", "DJ Nobody"])
        #expect(people.last?.page == nil)
        #expect(people.first?.page?.id == "p-2")
        #expect(people.first?.likeRequired == true)
        // Featured locales, home venue and gigs place a person in a locale, with friends there now.
        #expect(people.first?.homeVenue == nil)
        #expect(people.first?.locales?.map(\.id) == ["l-2"])
        #expect(people.last?.locales == nil)
        #expect(people.last?.homeVenue?.locale?.id == "l-1")
        #expect(people.last?.homeVenue?.friends?.first?.name == "Sam Okafor")
        #expect(people.last?.homeVenue?.friends?.first?.presence == .online)
        // An event's venue comes in its facet, with a name even while it's to be announced.
        #expect(people.last?.events?.first?.venue?.id == "v-1")
        #expect(people.last?.events?.last?.venue == nil)
        #expect(people.last?.events?.last?.venueName == "To be announced")
        #expect(people.last?.events?.first?.startDate == Date(timeIntervalSince1970: 1_791_604_800))
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
            _ = try await client.graphQL("{ nope }", as: [String: GraphQLValue].self)
            Issue.record("expected an error")
        } catch let AudienceKitError.graphQL(errors) {
            #expect(errors.first?.message == "Field 'nope' doesn't exist on type 'Query'")
            #expect(errors.first?.path == ["query", "nope"])
            #expect(errors.first?.extensions?["code"] == "undefinedField")
        }
    }

    @Test func aRejectedSessionEndsIt() async throws {
        let stub = Stub { _ in .json(status: 401, body: "{}") }
        let (client, store) = makeClient(stub)
        var events = client.sessionEvents.makeAsyncIterator()

        await #expect(throws: AudienceKitError.unauthorized) { try await client.venues() }

        #expect(try store.loadToken() == nil)
        #expect(await client.isSignedIn == false)
        #expect(await events.next() == .sessionEnded)
    }

    @Test func forbiddenIsNotASessionEnding() async throws {
        let stub = Stub { _ in .json(status: 403, body: "{}") }
        let (client, store) = makeClient(stub)

        await #expect(throws: AudienceKitError.forbidden) { try await client.venues() }
        #expect(try store.loadToken() == "session-token")
    }

    @Test func anOutdatedSDKIsToldToUpdate() async throws {
        let stub = Stub { _ in
            .json(status: 426, body: #"{"error":"update_required","platform":"ios","minimum_sdk_version":"0.3.0","message":"This version of the app is out of date."}"#)
        }
        let (client, store) = makeClient(stub)

        await #expect(throws: AudienceKitError.updateRequired(minimumSDKVersion: "0.3.0", message: "This version of the app is out of date.")) {
            try await client.venues()
        }
        #expect(try store.loadToken() == "session-token")
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
        } catch let AudienceKitError.network(error) {
            #expect(error.code == .notConnectedToInternet)
        }
    }

    @Test func reportsMalformedResponses() async throws {
        let stub = Stub { _ in .json(status: 200, body: #"{"data":{"venues":"nope"}}"#) }
        let (client, _) = makeClient(stub)

        do {
            _ = try await client.venues()
            Issue.record("expected an error")
        } catch AudienceKitError.decoding {}
    }
}

@Suite struct MobileOperations {
    @Test func findsTheClosestLocale() async throws {
        let stub = Stub { _ in
            .json(status: 200, body: #"{"data":{"closestLocale":{"id":"l-1","name":"Seattle","label":"SEA"}}}"#)
        }
        let (client, _) = makeClient(stub)

        let locale = try await client.closestLocale(near: Coordinates(latitude: 47.6, longitude: -122.3, beaconMajor: 0))

        #expect(locale?.name == "Seattle")
        let body = try #require(stub.requests.first).jsonBody()
        let near = try #require((body["variables"] as? [String: Any])?["near"] as? [String: Any])
        #expect(near["latitude"] as? Double == 47.6)
        #expect(near["longitude"] as? Double == -122.3)
        #expect(near["beaconMajor"] == nil)
    }

    @Test func setsAnRSVP() async throws {
        let stub = Stub { _ in
            .json(status: 200, body: #"{"data":{"rsvpEvent":{"event":{"id":"e-1","viewerRsvp":"ATTENDING"}}}}"#)
        }
        let (client, _) = makeClient(stub)

        let state = try await client.setRSVP(.attending, forEvent: "e-1")

        #expect(state == .attending)
        let body = try #require(stub.requests.first).jsonBody()
        let variables = try #require(body["variables"] as? [String: Any])
        #expect(variables["eventId"] as? String == "e-1")
        #expect(variables["state"] as? String == "ATTENDING")
    }

    @Test func registersTheDevice() async throws {
        let stub = Stub { _ in .json(status: 200, body: #"{"data":{"registerDevice":{"registered":true}}}"#) }
        let (client, _) = makeClient(stub)

        try await client.registerDevice(notificationToken: "apns")

        let body = try #require(stub.requests.first).jsonBody()
        #expect(body["operationName"] as? String == "RegisterDevice")
        #expect((body["variables"] as? [String: Any])?["notificationToken"] as? String == "apns")
    }

    @Test func decodesWithTheCallersDecoder() async throws {
        struct Payload: Decodable, Sendable { var when: Date }
        let stub = Stub { _ in .json(status: 200, body: #"{"data":{"when":"2026-10-06T20:00:00Z"}}"#) }
        let (client, _) = makeClient(stub)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let payload = try await client.graphQL("{ when }", as: Payload.self, decoder: decoder)

        #expect(payload.when == Date(timeIntervalSince1970: 1_791_316_800))
    }
}

@Suite struct AudienceResolution {
    @Test func usesTheSessionsAudienceClaim() async throws {
        let stub = Stub { _ in .json(status: 200, body: #"{"data":{"venues":[]}}"#) }
        let token = makeJWT(["id": "u-1", "audience_id": "from-token"])
        let (client, _) = makeClient(stub, audienceID: nil, token: token)

        _ = try await client.venues()

        #expect(stub.requests.map(\.path) == ["/v1/audience/from-token/graphql"])
    }

    @Test func looksUpTheHostsAudienceForAPlatformSession() async throws {
        let stub = Stub { request in
            if request.path == "/v1/branding" {
                return .json(status: 200, body: #"""
                {"audience":{"id":"from-branding","name":"Hot Mess","subdomain":"hotmess"},
                 "facebook_app_id":"100000000000002","theme":{"preset":"hot_mess","tagline":null,"light":{},"dark":{}}}
                """#)
            }
            return .json(status: 200, body: #"{"data":{"venues":[]}}"#)
        }
        let (client, _) = makeClient(stub, audienceID: nil, token: makeJWT(["id": "u-1"]))

        _ = try await client.venues()
        _ = try await client.venues()

        #expect(stub.requests.map(\.path) == [
            "/v1/branding", "/v1/audience/from-branding/graphql", "/v1/audience/from-branding/graphql",
        ])
    }

    @Test func needsAnAudienceOrAHost() async throws {
        let stub = Stub { _ in .json(status: 200, body: "{}") }
        let (client, _) = makeClient(stub, host: nil, audienceID: nil, token: "not-a-jwt")

        await #expect(throws: AudienceKitError.self) { try await client.venues() }
        #expect(stub.requests.isEmpty)
    }
}

@Suite struct Cover {
    static let admission = #"""
    {"id":"7d9f2c1e-3b4a-4e5f-8a6b-1c2d3e4f5a6b","status":"PENDING","night":"2026-10-09","amountCents":1000,
     "totalCents":1112,"currency":"usd","isRefundable":false,"passSecret":"c2VjcmV0LWtleS1mb3ItaG90LW1lc3MtY292ZXI=",
     "scanCount":0,"checkedInAt":null,"userName":"Rick Mark","userPhotoUrl":null,
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
        #expect(purchase.admission.totalCents == 1112)
        #expect(purchase.admission.venue?.name == "The Stud")
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
                {"data":{"doorVenues":[{"id":"v-1","name":"The Stud","photoUrl":null,
                  "cover":{"door":{"night":"2026-10-09","paidCount":12,"checkedInCount":8,"grossCents":12000}}}]}}
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

        let result = try await client.scanAdmission(venueID: "v-1", code: "HMC1.a.1.b")
        #expect(result.outcome == .reEntry)
        #expect(result.message.hasPrefix("Re-entry"))
        #expect(try #require(stub.requests.last).jsonBody()["variables"] as? [String: String]
            == ["venueId": "v-1", "code": "HMC1.a.1.b"])
    }

    @Test func decodesAVenuesCoverFacet() async throws {
        let stub = Stub { request in
            let id = (try? request.jsonBody()["variables"] as? [String: String])?["id"]
            if id == "v-2" {
                // A venue that takes no cover has no cover facet.
                return .json(status: 200, body: #"{"data":{"venue":{"id":"v-2","name":"Free Bar","cover":null}}}"#)
            }
            return .json(status: 200, body: #"""
            {"data":{"venue":{"id":"v-1","name":"The Stud","cover":{
              "charge":{"amountCents":1000,"totalCents":1112,"feeCents":112,"currency":"usd","night":"2026-10-09",
                "from":"21:00","payable":true,"event":null},
              "viewerAdmission":\#(Self.admission)}}}}
            """#)
        }
        let (client, _) = makeClient(stub)

        let coverResponse = try await client.venueCover(venueID: "v-1")
        let cover = try #require(coverResponse)
        #expect(cover.coverCharge?.totalCents == 1112)
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
        #expect(friends.map(\.presence) == [.online, .online, .offline, nil])
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
        #expect(Coordinate(wkt: "POINT (-122.5 37.25)") == Coordinate(latitude: 37.25, longitude: -122.5))
        #expect(Coordinate(wkt: "SRID=4326;POINT(1 2)") == Coordinate(latitude: 2, longitude: 1))
        #expect(Coordinate(wkt: "POLYGON ((0 0, 1 1))") == nil)
        #expect(Coordinate(wkt: "") == nil)
    }

    @Test func readsTheAudienceClaim() {
        #expect(AudienceKitClient.claims(of: makeJWT(["audience_id": "a-1"]))?.audienceID == "a-1")
        #expect(AudienceKitClient.claims(of: makeJWT(["id": "u"]))?.audienceID == nil)
        #expect(AudienceKitClient.claims(of: "garbage") == nil)
    }

    @Test func inMemoryStoreRoundTrips() throws {
        let store = InMemoryTokenStore()
        #expect(try store.loadToken() == nil)
        try store.saveToken("t")
        #expect(try store.loadToken() == "t")
        try store.deleteToken()
        #expect(try store.loadToken() == nil)
    }
}
