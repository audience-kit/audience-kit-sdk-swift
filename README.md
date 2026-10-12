# AudienceKit Swift SDK

Swift client for the AudienceKit API: sign people in with Facebook, then read an
audience's venues, people, locales and events over GraphQL, and its branding over REST.

- Swift 6, `async`/`await`, everything `Sendable`
- No dependencies. Facebook Login stays in your app: the SDK takes the access
  token Facebook gives you.
- iOS 16+, macOS 13+, and Linux (without the keychain store)

## Installation

Add the package with Swift Package Manager:

```swift
.package(url: "https://github.com/audience-kit/audience-kit-sdk-swift.git", branch: "main")
```

and depend on the products you need (in Xcode, **File › Add Package
Dependencies…** with the same URL):

| Product | What it is | Depends on |
| --- | --- | --- |
| `AudienceCore` | The session: configuration, sign-in, the credential and its stores, GraphQL transport, branding, errors | nothing |
| `AudienceKit` | The member-facing API: venues, people, locales, events, RSVPs, location, cover | AudienceCore |
| `AudienceKitUI` | SwiftUI building blocks and the generated `DesignTokens` | AudienceCore, AudienceKit |

```swift
.target(name: "MyApp", dependencies: [
    .product(name: "AudienceKit", package: "audience-kit-sdk-swift"),
    .product(name: "AudienceKitUI", package: "audience-kit-sdk-swift"),
])
```

## Configure a client

```swift
import AudienceKit

let client = AudienceKitClient(
    configuration: AudienceKitConfiguration(
        baseURL: URL(string: "https://api.audiencekit.com")!, // the default
        host: "hotmess.admin.audiencekit.com",              // or the audience's verified domain
        facebookAppID: "<your Facebook app ID>"             // the Facebook app this build signs in with
    ),
    credentialStore: KeychainCredentialStore(service: "social.hotmess.session")
)
```

| Setting | What it does |
| --- | --- |
| `baseURL` | The API. `http://localhost:3000` for a local server. |
| `host` | Names the audience. Sent with sign-in so the API checks the Facebook token against the audience's Facebook apps and binds the session to the audience, and used to fetch branding. `<subdomain>.admin.audiencekit.com` works for every audience; the audience's own domain works once it's verified. Without a host, the API only accepts tokens from the AudienceKit platform Facebook app. |
| `audienceID` | The audience's UUID. Optional: the client reads it from the stored credential, or looks it up from `host`. |
| `facebookAppID` | The Facebook app the build uses (production, staging or development). It must be one of the audience's apps. |
| `coverPassPrefix` | The prefix on cover pass QR codes, `HMC1` by default. |
| `feeLabel` | What to call the audience's fee on a cover charge, e.g. "Hot Mess fee". |

`KeychainCredentialStore` keeps the session's `Credential` in the keychain
(readable after first unlock, so background launches can use it), as a
versioned JSON item; an item from an older SDK reads as no session.
`InMemoryCredentialStore` is for tests and previews, and you can write your own
`CredentialStore`.

## Sign in

Run Facebook Login in your app, then exchange its access token:

```swift
let device = DeviceDescription(
    identifier: UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString,
    model: "iPhone17,1",
    version: "2.0",
    build: "42"
)
let result = try await client.signIn(facebookAccessToken: token.tokenString, device: device)
print("Signed in as \(result.credential.userId) in audience \(result.credential.audienceId ?? "-")")
```

This calls `POST /v1/token`, which answers with the session's `Credential`:
`token`, `userId`, `audienceId`, `role`, the GraphQL `endpoint` the token was
issued for, `venueDeviceId` and `expiresAt`. The SDK stores it and sends the
token on every later call as `Authorization: Bearer <token>`, together with
`X-AudienceKit-API-Version: 2026-10-11`, the API contract it speaks
(`AudienceKitSDK.apiVersion`). The response has no profile; read `me()` for
the person's name.

Sign-in can fail with code `SIGN_IN_REJECTED` (the Facebook token is invalid,
or from an app the audience doesn't use) or `SIGN_IN_FAILED` (the message is
the API's).

A credential minted elsewhere (a venue device's, one the platform console
handed over) becomes the session with `try await client.adopt(credential:)`,
and a platform-console session moves to an audience with
`try await client.switchAudience(to: audienceID)` (`POST /v1/admin/choices`).
GraphQL then goes to the API instance and audience the credential names.

## Session ends

Sessions don't expire, but they end when the person signs out elsewhere or
removes the app from Facebook. Then any call throws an `AudienceKitError` with
code `UNAUTHENTICATED` (`error.isUnauthenticated`), the client deletes the
credential, and `sessionEvents` yields `.sessionEnded`. Every access to
`sessionEvents` is its own subscription, so watch it from as many places as
you like:

```swift
Task {
    for await event in client.sessionEvents where event == .sessionEnded {
        showSignIn()
    }
}
```

The event comes once per session, however many calls the API refused at the
same time, and a refusal of an older token never ends a newer sign-in. A 403
(`FORBIDDEN`, e.g. no staff role) or a network failure doesn't end the session.

Connections the SDK doesn't make itself (a Server-Sent Events stream) carry
`client.sessionToken()` and the same headers as every call
(`request.setAudienceKitHeaders(environment:token:)`). When the server refuses
that token there (the stream answers 401), hand the token back and the session
ends the same way:

```swift
await client.sessionRejected(token: token)
```

## Realtime: one cable for every subscription

GraphQL subscriptions (chat rooms, notifications) ride one Action Cable
websocket. Keep one `AudienceCable` for the app and subscribe every feature on
it; the socket opens with the first subscription and closes after the last one
ends, so subscriptions that live while the app is in the foreground keep it open
exactly then. The client makes one wired to its session: the socket opens on
the API instance the stored credential names (`wss://<origin>/connection`;
the configured base URL before sign-in), its handshake carries
`Authorization: Bearer <token>` and the same `X-AudienceKit-*` headers as every
call, and a connection the server closes as `unauthorized` ends the session
like an HTTP 401. Pass `endpoint: .staff` for a staff tool's subscriptions,
and `url:` to point a development build at a local cable.

```swift
let cable = client.makeCable()

for await event in await cable.subscribe(query: document, variables: ["id": "…"], audienceID: audienceID) {
    switch event {
    case .subscribed: break                 // the operation went out (again, after a reconnect)
    case .result(let json): handle(json)    // { "data": …, "errors": … }
    case .rejected: break                   // the channel was turned away; the stream ends
    case .disconnected(_, let reconnects): break // dropped or quiet; resubscribes itself unless `reconnects` is false
    }
}
```

A socket that hears nothing for 12 seconds (Action Cable pings every 3) counts
as dropped. The cable reconnects with backoff from one second to half a minute,
then subscribes and executes every live operation again. Call `disconnect()` on
signing out.

`try await client.signOut()` forgets the session on the device, yields
`.signedOut`, then revokes the token with `DELETE /v1/token`. The device is
signed out even when that call fails (offline, say); the thrown error means the
token may still be alive on the server. Log out of Facebook in your app as
well.

## Read the audience

```swift
let venues = try await client.venues()   // [Venue]: page name and photos, locale, location
let people = try await client.people()   // [Person]
let locales = try await client.locales() // [AudienceLocale]
let me = try await client.me()           // SelfUser?: me { self }, your own profile
let audience = try await client.audience() // name, subdomain, theme tokens

for venue in venues {
    print(venue.name, venue.location?.coordinate as Any, client.url(for: venue.page?.photoUrl) as Any)
}
```

Objects' `id` fields are the records' UUIDs, the same IDs the REST endpoints
and `node(id:)` take; there is one ID per record everywhere.

Run any other operation and decode it into your own type:

```swift
struct VenueNames: Decodable, Sendable {
    struct Venue: Decodable, Sendable { let id: String; let name: String? }
    struct List: Decodable, Sendable { let nodes: [Venue] }
    struct Venues: Decodable, Sendable { let list: List }
    struct Audience: Decodable, Sendable { let venues: Venues }
    let audience: Audience
}

let names = try await client.graphQL(
    "query VenueNames { audience { venues { list { nodes { id name } } } } }",
    operationName: "VenueNames",
    as: VenueNames.self
)
```

Variables are `[String: GraphQLValue]`, which you can write as literals:
`variables: ["id": "…"]`. Dates decode from ISO 8601 strings (fractional
seconds or not) with the default decoder, `JSONDecoder.audienceKit`; pass your
own `decoder` for other strategies. If the response has `errors`, the call
throws an `AudienceKitError` whose `code` and `message` are the first error's
(`extensions.code`: `UNAUTHENTICATED`, `FORBIDDEN`, `NOT_FOUND`, `INVALID`,
`RATE_LIMITED`, `CONFLICT`, `INTERNAL`), with `INVALID`'s per-field messages in
`fields` and every error in `errors`.

## Branding

Branding is public, so you can skin the app before sign-in:

```swift
let branding = try await client.branding() // GET /v1/branding?host=<host>
branding.audience.name
branding.theme.tagline
if let accent = branding.theme.color("accent", dark: colorScheme == .dark) {
    Color(red: accent.red, green: accent.green, blue: accent.blue, opacity: accent.alpha)
}
```

`AudienceKitUI.DesignTokens` (add `import AudienceKitUI`) carries the whole design system: every theme's colours (`DesignTokens.hotMess`,
`.hotMessDark`, `.light`, `.dark`), the presets by key (`DesignTokens.presets["hot_mess"]`), and
`Spacing`, `Radius`, `Size`, `Opacity` and `Typography`. It's generated from
the AudienceKit design system's tokens, so don't edit it by hand. Overlay the
audience's `branding.theme` overrides on its preset's colours.

## Mobile operations

The calls the Hot Mess apps make for the signed-in member:

```swift
let here = Coordinate(latitude: 37.77, longitude: -122.42)
let locale = try await client.closestLocale(near: here, beaconMajor: beacon?.major) // AudienceLocale?
try await client.setRSVP(.attending, forEvent: eventID) // reads back rsvp { mine }
try await client.registerDevice(token: hexToken, appId: Bundle.main.bundleIdentifier, sandbox: isDebugBuild)
```

`reportLocation` records where the member is and says where that is: the
`venue` they're in, else their `locale` and its `nearbyVenues`. Select the
fields you need, including the module mixins the screen reads (such as
`venue { friends { list { name } } }` or `audience { me { ping { friendPings { id } } } }`),
and decode into your own type. `$position` is a `CoordinatesInput`:
`here.coordinatesInput(beaconMajor: beacon?.major)`, or `here.graphQLValue`
with no beacon.

```swift
let document = """
mutation ReportLocation($position: CoordinatesInput!) {
  reportLocation(input: { position: $position }) { venue { id name } locale { id name } nearbyVenues { id name distance } }
}
"""
let now = try await client.graphQL(document, variables: ["position": here.graphQLValue], as: MyNowResponse.self)
```

The API also serves `venues { venue(id:) }`, `events { event(id:) }`,
`people { person(id:) }` and `locale(id:)` by UUID,
`audience { venues { list(near:) } }` nearest first with each `distance`, and each
locale's and venue's upcoming events
(`events { upcoming { nodes { … } } }`: mixins, whose lists are Relay connections).

## Cover

A venue's `coverCharge` is tonight's price; when `payable`, the member can pay
it in the app and gets a pass:

```swift
let cover = try await client.venueCover(venueID: venueID) // coverCharge, viewerAdmission
let purchase = try await client.buyCover(venueID: venueID)
let pass: Admission
if purchase.isSquare {
    // Square: SQIPInAppPaymentsSDK.squareApplicationID = purchase.squareApplicationId, then take a card,
    // Apple Pay or Google Pay with Square's In-App Payments SDK and send its nonce:
    pass = try await client.payCover(admissionID: purchase.admission.id, sourceID: nonce)
} else {
    // Stripe Connect direct charge: present PaymentSheet with
    // purchase.paymentIntentClientSecret, STPAPIClient.shared.publishableKey = purchase.publishableKey
    // and STPAPIClient.shared.stripeAccount = purchase.stripeAccountId. Then:
    pass = try await client.confirmCover(admissionID: purchase.admission.id)
}
let passes = try await client.admissions()
_ = try await client.refundAdmission(admissionID: pass.id) // while pass.isRefundable
```

Make the pass's QR code on the device, so it works with no signal. It changes
every 30 seconds (Apple platforms, CryptoKit) and starts with the audience's
`coverPassPrefix`:

```swift
let code = client.coverPassCode(for: pass)
// or CoverPass.code(admissionID: pass.id, secret: secret, prefix: "HMC1")
```

Door staff see venues in `doorVenues()` and check codes with
`scanAdmission(venueID:code:)`, which returns an `outcome` (`.admit`,
`.reEntry`, `.expired`, ...) and a `message` for the door.

## REST endpoints

For anything GraphQL doesn't cover, send the request through the client so it
carries the session and handles a rejected session the same way:

```swift
let data = try await client.data(for: APIRequest(method: "POST", path: "/", authenticated: false))
```

## Errors

Every failure is an `AudienceKitError`: a `code`, a `message` for the person,
and detail where there is any (`status`, `fields`, `errors`, `underlying`,
`minimumSDKVersion`). Switch on `error.code` against `AudienceKitError.Code`:

| Code | When |
| --- | --- |
| `UNAUTHENTICATED` | The API rejected the session (401). The session has ended. |
| `FORBIDDEN` | 403, e.g. a session bound to another audience, or no staff role. |
| `NOT_FOUND` | 404, or a GraphQL error saying so. |
| `INVALID` | Refused input; `fields` has the per-field messages. |
| `RATE_LIMITED`, `CONFLICT`, `INTERNAL` | As the API says. |
| `NOT_SIGNED_IN` | No stored credential for a call that needs one. |
| `SIGN_IN_REJECTED`, `SIGN_IN_FAILED` | `POST /v1/token` refused the login (401), or failed (400). |
| `UPDATE_REQUIRED`, `UNSUPPORTED_API_VERSION` | The API no longer serves this SDK (426) or its API version (400). |
| `HTTP` | Any other unsuccessful status (`status`). |
| `NETWORK` | No response: offline, timeout, TLS (`underlying`). |
| `DECODING` | The response wasn't what the SDK expected. |
| `GRAPHQL` | A GraphQL error with no `extensions.code`. |
| `MISSING_CONFIGURATION`, `STORAGE` | Setup problems. |

A code the SDK doesn't know is passed through as the API sent it. The
constants `AudienceKitError.unauthorized`, `.forbidden`, `.notFound`,
`.notSignedIn` and `.signInRejected` are the values the SDK throws, for tests.

Server-defined enums (`RSVPState`, `Presence`, `PaymentProvider`,
`PersonEventInvolvement.Relationship`, `AudienceKitEnvironment`) keep a value
the SDK doesn't know as `.unknown(String)` and send it back unchanged;
`known` lists the cases the SDK does know.

## Development

Run from the repository root:

```sh
swift build
swift test
xcodebuild build -scheme AudienceKit-Package -destination 'generic/platform=iOS Simulator'
```

Tests stub HTTP with a `URLProtocol`, so they run offline.

## License

MIT. See [LICENSE](LICENSE).
