# Changelog

## 0.18.0 (2026-10-12)

The pre-release breaking-change sweep (`PRE_RELEASE_SWEEP.md`, section 4): the Swift SDK's part of the contract the
API breaks once, before the first release. Everything below is breaking; there are no deprecations or shims.
Pairs with API version `2026-10-11`, which the SDK sends as `X-AudienceKit-API-Version` on every request.

### Credential and store (4.2)

- `Credential` replaces the bare JWT: `token`, `userId`, `audienceId?`, `role`, `endpoint` (the GraphQL endpoint
  the token was issued for, as a URL), `venueDeviceId?`, `expiresAt?` (`Date`) and `apiVersion`. It is what
  `POST /v1/token` (every variant) answers with, and it is `Codable`.
- `CredentialStore` (`load()`, `save(_:)`, `delete()`) replaces `TokenStore`; `KeychainCredentialStore` and
  `InMemoryCredentialStore` replace `KeychainTokenStore` and `InMemoryTokenStore`. The keychain item is JSON
  `{ "v": 1, "credential": { … } }`; a raw token from an older SDK reads as no session (everyone signs in again once).
  `AudienceSession.init` takes `credentialStore:`.
- `SignInResult` is `{ credential }` (plus `userId`); it no longer carries `token` or `user`. Read `me()` for the name.
- `AudienceSession.credential()` returns the stored credential; `sessionToken()` is its token.
- The audience comes from the stored credential's `audienceId`, then the configured `audienceID`, then the host's
  branding. Nothing decodes the JWT's `audience_id` claim any more.
- `Authorization: Bearer <token>` replaces `JWT <token>`.

### Errors and enums (4.3)

- `AudienceKitError` is a struct: `code`, `message`, `status?`, `fields`, `errors`, `underlying?`,
  `minimumSDKVersion?`. Codes are the API's `UNAUTHENTICATED`, `FORBIDDEN`, `NOT_FOUND`, `INVALID`, `RATE_LIMITED`,
  `CONFLICT`, `INTERNAL` (from GraphQL `extensions.code` or a REST `error`) and the SDK's `NOT_SIGNED_IN`,
  `SIGN_IN_REJECTED`, `SIGN_IN_FAILED`, `HTTP`, `NETWORK`, `DECODING`, `GRAPHQL`, `MISSING_CONFIGURATION`,
  `STORAGE`, `UPDATE_REQUIRED`, `UNSUPPORTED_API_VERSION` (`AudienceKitError.Code`). `INVALID` carries
  `extensions.fields` as `fields`. Static values `.notSignedIn`, `.unauthorized`, `.signInRejected`, `.forbidden`,
  `.notFound` and factories `.signInFailed(message:)`, `.http(status:)`, `.network(_:)`, `.decoding(_:)`,
  `.graphQL(_:)`, `.missingConfiguration(_:)`, `.storage(_:)`, `.updateRequired(minimumSDKVersion:message:)`
  remain for pattern matching by equality; `catch let AudienceKitError.graphQL(errors)` becomes
  `catch let error as AudienceKitError` and a look at `error.code` / `error.errors`.
- `RSVPState`, `Presence`, `PersonEventInvolvement.Relationship` and `AudienceKitEnvironment` gain
  `.unknown(String)` and lose `CaseIterable` (`known` lists the known cases). `Presence` no longer turns an unknown
  value into `.offline`; use `isReachable`. `GraphQLError.code` reads `extensions.code`.
- `CoverPurchase.provider` is a `PaymentProvider` (`.stripe`, `.square`, `.unknown`), not a `String`.

### Models (4.4)

- `Queries` is internal. Run your own documents through `graphQL(_:variables:operationName:endpoint:as:decoder:)`.
- Every model field is `let`; every model has a public memberwise initializer (`Venue(id:name:hidden:order:…)`,
  `Person(id:name:…)`, `Admission(id:status:night:…)`, `VenueCover(id:name:coverCharge:viewerAdmission:)`, …).
- Nullability follows the schema: `Venue.name`/`Person.name` are the records' own names (nullable, with `name` falling
  back to the Page's), `Admission.venue` is non-optional, `Admission.checkedInAt`, `userName`, `userPhotoUrl`,
  `passSecret`, `event` stay optional; fields the SDK's query may leave out (`tags`, `locales`, `presence`, …) are
  optional and nil when not asked. `VenueCover`/`DoorVenue` properties are read-only.

### Session and surface (4.5)

- `signOut()` is `async throws`: forgets the credential, yields `.signedOut`, then `DELETE /v1/token`. The device is
  signed out even when the revocation fails; the error says the token may still be alive.
- `sessionEvents` is a new `AsyncStream` per access: subscribe from anywhere, as often as needed. A subscriber hears
  the events from its subscription on.
- `adopt(credential:)` makes a credential minted elsewhere the session; `switchAudience(to:)` moves a
  platform-console session to an audience (`POST /v1/admin/choices`). GraphQL goes to the origin of the credential's
  `endpoint`, at the audience's `graphql` or `staffql` path.
- One `Coordinate` type: `Coordinates` is gone. `closestLocale(near: Coordinate, beaconMajor:)`;
  `Coordinate.coordinatesInput(beaconMajor:beaconMinor:)` / `graphQLValue` build a `CoordinatesInput`;
  `Coordinate.wkt` writes a point.
- `Location.coordinate: Coordinate?` replaces the WKT `point: String?` (`Location(id:coordinate:…)`).
- Dates are `Date`: `PersonEvent.startAt` (`startDate` is gone), `Admission.checkedInAt`, `Credential.expiresAt`.
  They decode from ISO 8601 strings with or without fractional seconds whatever decoder is used; `graphQL`'s default
  decoder is `JSONDecoder.audienceKit`, and `ISO8601.date(from:)` / `string(from:)` are public. `night` and `from`
  stay strings (a calendar date and a local time, not instants).
- `AudienceKitConfiguration.coverPassPrefix` (default `HMC1`) and `feeLabel` (default "Service fee").
  `CoverPass.code(admissionID:secret:prefix:at:)` takes the prefix (`CoverPass.defaultPrefix`), and
  `AudienceSession.coverPassCode(for:at:)` uses the configured one.
- `registerDevice(token:appId:sandbox:)` replaces `registerDevice(notificationToken:)`.
- `Queries.rsvpEvent` selects `rsvp { mine }` instead of the deprecated `viewerRsvp` (4.1).
- REST error bodies `{ "error": "<code>", "message": "…" }` become coded errors; a 400 `unsupported_api_version`
  is `UNSUPPORTED_API_VERSION`.

Money as `Money { cents, currency }` is not in this release: cents fields wait for the API's wave 1.

### Migrating hot_mess_ios

| Before | After |
| --- | --- |
| `KeychainTokenStore(service:account:)` / `tokenStore:` | `KeychainCredentialStore(service:account:)` / `credentialStore:` |
| `Self.tokenStore.saveToken(session.token)` | `try await audienceKit.adopt(credential: session.credential)` |
| `session.token`, `session.user.id`, `session.user.name` | `session.credential.token`, `session.credential.userId`; the name comes from `me()` |
| `Task { await audienceKit.signOut() }` | `Task { try? await audienceKit.signOut() }` (local sign-out happens first either way) |
| `catch AudienceKitError.unauthorized` | `catch let error as AudienceKitError where error.isUnauthenticated` |
| `switch error { case .notSignedIn, .unauthorized: … }` | `switch error.code { case AudienceKitError.Code.notSignedIn, .Code.unauthenticated: … }` |
| `case let .http(status)` | `error.status` (code `HTTP`, or the API's) |
| `case let .network(urlError)` | `error.underlying` (code `NETWORK`) |
| `AudienceKit.Coordinates(latitude:longitude:beaconMajor:)` | `Coordinate(latitude:longitude:)` + `beaconMajor:` on `closestLocale`, or `coordinatesInput(beaconMajor:)` |
| `Coordinate(wkt:)` | unchanged |
| `registerDevice` via your own document | `audienceKit.registerDevice(token:appId:sandbox:)` |
| `audienceKit.sessionEvents` iterated once | iterate anywhere; each access is a subscription |
| `Presence` fallback `.offline` | `.unknown(value)`; use `isReachable` |
| `CoverPass.code(admissionID:secret:)` | unchanged (prefix `HMC1`), or `audienceKit.coverPassCode(for:)` |
| `Authorization: JWT` on your own cable connection | `Authorization: Bearer`, and send `X-AudienceKit-API-Version: 2026-10-11` |

## 0.17.0

Read `me { self }` and `me { cover }`; cover reads moved to `tickets { cover }`; GlobalID gone.
