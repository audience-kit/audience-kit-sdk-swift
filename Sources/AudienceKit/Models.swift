import AudienceCore
import Foundation

/// The audience a client is scoped to.
public struct Audience: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var subdomain: String
    public var theme: AudienceTheme?
}

/// An audience's look, as GraphQL returns it: a preset, a tagline and color token overrides.
public struct AudienceTheme: Codable, Sendable, Hashable {
    public var preset: String
    public var tagline: String?
    public var light: [ThemeToken]
    public var dark: [ThemeToken]
}

/// One design-system color token, e.g. `accent` = `#b8236f`.
public struct ThemeToken: Codable, Sendable, Hashable {
    public var name: String
    public var value: String
}

/// The Facebook page behind a venue or person: its name and pictures.
public struct Page: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    /// Profile picture, as the API sends it. Use ``AudienceKitClient/url(for:)`` to resolve relative paths.
    public var photoUrl: String?
    public var bannerUrl: String?
}

/// A city or region the audience is active in.
public struct AudienceLocale: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String?
    public var label: String?
    public var cityNames: [String]?
    public var bannerUrl: String?
    /// Its Google place ID (a city or region), when an admin has set one.
    public var googlePlaceId: String?
}

/// A place: a Google place with a point.
public struct Location: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    /// The point as the API serializes it (WKT, e.g. `POINT (-122.42 37.77)`).
    public var point: String?
    /// Its Google place ID, when an admin or the researcher has set one.
    public var googlePlaceId: String?
    /// Its full address, when known.
    public var address: String?

    /// ``point`` parsed into latitude and longitude, when it is a WKT point.
    public var coordinate: Coordinate? { point.flatMap(Coordinate.init(wkt:)) }
}

/// A venue in the audience.
public struct Venue: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var hidden: Bool
    public var order: Int
    public var photoUrl: String?
    public var bannerUrl: String?
    /// Its Facebook Page; venues added without one have none.
    public var page: Page?
    public var locale: AudienceLocale
    public var location: Location?
    /// The audience's tags on it, by name; nil when the query didn't ask.
    public var tags: [Tag]?
    private var venueName: String?

    /// The venue's own name, falling back to its Facebook Page's.
    public var name: String { venueName ?? page?.name ?? "" }

    private enum CodingKeys: String, CodingKey {
        case id, hidden, order, photoUrl, bannerUrl, page, locale, location, tags
        case venueName = "name"
    }
}

/// A person (performer, promoter, DJ...) the audience follows.
public struct Person: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var order: Int
    public var global: Bool
    public var likeRequired: Bool
    /// Their Facebook Page; talent added by name has none yet.
    public var page: Page?
    /// The venue they are based at, if any: the API's `venues { home }`.
    public var homeVenue: PersonVenue?
    /// The locales they're featured in; nil when the query didn't ask.
    public var locales: [AudienceLocale]?
    /// Upcoming events they host or play and those of the troupes they're in, soonest first: the API's
    /// `events { upcoming }`, or the nodes of `events { involvements }`; nil when the query asked for neither.
    public var events: [PersonEvent]?
    /// The audience's tags on them, by name; nil when the query didn't ask.
    public var tags: [Tag]?
    private var personName: String?
    private var involvements: [PersonEventInvolvement]?

    /// Their name as the audience shows it, falling back to their Facebook Page's.
    public var name: String { personName ?? page?.name ?? "" }

    /// The same events as `events`, with how they're on each: themselves, or through a troupe (`via`); nil when the
    /// query didn't ask.
    public var eventInvolvements: [PersonEventInvolvement]? { involvements }

    private enum CodingKeys: String, CodingKey {
        case id, order, global, likeRequired, page, locales, tags, venues, events
        case personName = "name"
    }

    /// The API's `venues` facet.
    private enum VenuesKeys: String, CodingKey { case home }
    /// The API's `events` facet: two connections.
    private enum EventsKeys: String, CodingKey { case upcoming, involvements }
    private enum ConnectionKeys: String, CodingKey { case nodes, edges }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        order = try container.decode(Int.self, forKey: .order)
        global = try container.decode(Bool.self, forKey: .global)
        likeRequired = try container.decode(Bool.self, forKey: .likeRequired)
        page = try container.decodeIfPresent(Page.self, forKey: .page)
        homeVenue = try container.decodeIfPresent(VenuesFacet.self, forKey: .venues)?.home
        locales = try container.decodeIfPresent([AudienceLocale].self, forKey: .locales)
        let eventsFacet = try container.decodeIfPresent(EventsFacet.self, forKey: .events)
        involvements = eventsFacet?.involvements?.edges
        // `Queries.people` asks for the involvements alone: their nodes are the events.
        events = eventsFacet?.upcoming?.nodes ?? involvements?.map(\.event)
        tags = try container.decodeIfPresent([Tag].self, forKey: .tags)
        personName = try container.decodeIfPresent(String.self, forKey: .personName)
    }

    /// Writes the API's shape, so an encoded person decodes back the same.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(order, forKey: .order)
        try container.encode(global, forKey: .global)
        try container.encode(likeRequired, forKey: .likeRequired)
        try container.encodeIfPresent(page, forKey: .page)
        try container.encodeIfPresent(locales, forKey: .locales)
        try container.encodeIfPresent(tags, forKey: .tags)
        try container.encodeIfPresent(personName, forKey: .personName)
        if let homeVenue {
            var venues = container.nestedContainer(keyedBy: VenuesKeys.self, forKey: .venues)
            try venues.encode(homeVenue, forKey: .home)
        }
        if events != nil || involvements != nil {
            var eventsFacet = container.nestedContainer(keyedBy: EventsKeys.self, forKey: .events)
            if let events {
                var upcoming = eventsFacet.nestedContainer(keyedBy: ConnectionKeys.self, forKey: .upcoming)
                try upcoming.encode(events, forKey: .nodes)
            }
            if let involvements {
                var connection = eventsFacet.nestedContainer(keyedBy: ConnectionKeys.self, forKey: .involvements)
                try connection.encode(involvements, forKey: .edges)
            }
        }
    }

    /// `venues { home }`.
    private struct VenuesFacet: Decodable {
        var home: PersonVenue?
    }

    /// `events { upcoming { nodes } involvements { edges } }`, either of which the query may leave out.
    private struct EventsFacet: Decodable {
        var upcoming: NodeList<PersonEvent>?
        var involvements: InvolvementEdges?
    }

    /// A `PersonEventConnection`'s edges. Edges and nodes are nullable in the schema; null ones are skipped.
    private struct InvolvementEdges: Decodable {
        var edges: [PersonEventInvolvement]?

        private struct Edge: Decodable {
            var node: PersonEvent?
            var relationship: PersonEventInvolvement.Relationship?
            var role: String?
            var via: PersonEventInvolvement.Troupe?
        }

        private enum CodingKeys: String, CodingKey { case edges }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let raw = try container.decodeIfPresent([Edge?].self, forKey: .edges)
            edges = raw?.compactMap { (edge: Edge?) -> PersonEventInvolvement? in
                guard let edge, let node = edge.node else { return nil }
                return PersonEventInvolvement(event: node, relationship: edge.relationship ?? .direct,
                                              role: edge.role, via: edge.via)
            }
        }
    }
}

/// A Relay connection's `nodes`, skipping null ones; nil when the query selected edges instead.
struct NodeList<Item: Decodable>: Decodable {
    var nodes: [Item]?

    private enum CodingKeys: String, CodingKey { case nodes }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nodes = try container.decodeIfPresent([Item?].self, forKey: .nodes)?.compactMap { $0 }
    }
}

/// How a person is on one of their upcoming events: themselves, or through a troupe they're in.
public struct PersonEventInvolvement: Codable, Sendable, Hashable, Identifiable {
    public enum Relationship: String, Codable, Sendable, Hashable, CaseIterable {
        /// They host or play it themselves.
        case direct = "DIRECT"
        /// A troupe they're in hosts or plays it.
        case troupe = "TROUPE"

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Relationship(rawValue: raw.uppercased()) ?? .direct
        }
    }

    /// The troupe an event comes through.
    public struct Troupe: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var name: String?
    }

    public var event: PersonEvent
    public var relationship: Relationship
    /// Their role on it, like host or performer: the troupe's when it's through one.
    public var role: String?
    /// The troupe it comes through, for showing "with <troupe>"; nil when it's their own.
    public var via: Troupe?

    public var id: String { event.id }

    private enum CodingKeys: String, CodingKey {
        case event = "node", relationship, role, via
    }
}

/// A venue as a person's home venue or gig carries it.
public struct PersonVenue: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String?
    public var photoUrl: String?
    public var locale: AudienceLocale?
    /// The signed-in user's friends who are there now.
    public var friends: [Friend]?
}

/// One of a person's upcoming events.
public struct PersonEvent: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String?
    /// ISO 8601.
    public var startAt: String?
    /// Its venue's locale, or its series' while the venue is still to be announced.
    public var locale: AudienceLocale?
    /// The audience's tags on it, by name; nil when the query didn't ask.
    public var tags: [Tag]?
    /// The API's `venue` facet: a display name and the venue, if any.
    private var venueFacet: VenueFacet?

    /// Where it is; nil while the venue is still to be announced, or when the query didn't ask.
    public var venue: PersonVenue? {
        get { venueFacet?.venue }
        set { venueFacet = VenueFacet(name: venueFacet?.name, venue: newValue) }
    }

    /// Its venue's name as the API shows it, e.g. "To be announced" when there is none; nil when the query didn't ask.
    public var venueName: String? { venueFacet?.name }

    public var startDate: Date? {
        startAt.flatMap { try? Date($0, strategy: .iso8601) }
    }

    private struct VenueFacet: Codable, Sendable, Hashable {
        var name: String?
        var venue: PersonVenue?
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, startAt, locale, tags
        case venueFacet = "venue"
    }
}

/// One of the audience's own labels, like "Drag" or "Resident DJ", on its people, events and venues.
public struct Tag: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    /// A `#rrggbb` color for its chip, or nil for the theme's accent.
    public var color: String?
    /// Whether people can identify with it (see ``TribeIdentification``); nil when the query didn't ask.
    public var tribe: Bool?
}

/// Someone identifying with one of the audience's tribes. A private one may be sensitive (HIV status, say): the API
/// only ever shows it to them and to people in the same tribe, and apps should keep it discreet.
public struct TribeIdentification: Codable, Sendable, Hashable {
    public var tag: Tag
    public var isPrivate: Bool
}

/// The tribes people can identify with in an audience, and which of them the signed-in user has.
public struct Tribes: Sendable, Hashable {
    public var available: [Tag]
    public var mine: [TribeIdentification]
}

/// One of the signed-in user's friends.
public struct Friend: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String?
    public var facebookId: String?
    /// Whether they can be reached now; nil when the query didn't ask.
    public var presence: Presence?
}

/// The signed-in user.
public struct User: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String?
    public var firstName: String?
    public var lastName: String?
    public var emailAddress: String?
    public var isAdmin: Bool?
    /// Whether they can be reached now; nil when the query didn't ask.
    public var presence: Presence?
}

/// Anything with an ID, as `node(id:)` returns it.
public struct Node: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    /// The GraphQL type name, e.g. `Venue`.
    public var typename: String?

    enum CodingKeys: String, CodingKey {
        case id
        case typename = "__typename"
    }
}

/// A Relay global ID, which the API builds from a Rails GlobalID: base64url of `gid://<app>/<Model>/<id>`.
/// `node(id:)` takes these; objects' own `id` fields are their records' UUIDs.
public struct GlobalID: Sendable, Hashable {
    /// The model name, e.g. `Venue`.
    public var modelName: String
    /// The record's database ID, usually a UUID, as the REST endpoints take it.
    public var modelID: String

    /// Decodes a Relay global ID. Returns `nil` for IDs that aren't GlobalIDs.
    public init?(_ id: String) {
        var base64 = id.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)

        guard let data = Data(base64Encoded: base64), let uri = String(data: data, encoding: .utf8),
              uri.hasPrefix("gid://")
        else { return nil }

        let parts = uri.dropFirst("gid://".count).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 3, !parts[1].isEmpty, !parts[2].isEmpty else { return nil }

        modelName = String(parts[1])
        modelID = String(parts[2].split(separator: "?").first ?? parts[2])
    }
}

/// A device's position, for the GraphQL `CoordinatesInput`. A beacon's major value names a locale.
public struct Coordinates: Sendable, Hashable {
    public var latitude: Double
    public var longitude: Double
    public var beaconMajor: Int?
    public var beaconMinor: Int?

    public init(latitude: Double, longitude: Double, beaconMajor: Int? = nil, beaconMinor: Int? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.beaconMajor = beaconMajor
        self.beaconMinor = beaconMinor
    }

    /// The value to pass as a `CoordinatesInput` variable. Zero beacon values mean no beacon.
    public var graphQLValue: GraphQLValue {
        var object: [String: GraphQLValue] = ["latitude": .double(latitude), "longitude": .double(longitude)]
        if let beaconMajor, beaconMajor != 0 { object["beaconMajor"] = .int(beaconMajor) }
        if let beaconMinor, beaconMinor != 0 { object["beaconMinor"] = .int(beaconMinor) }
        return .object(object)
    }
}

/// Whether the signed-in user is going to an event.
public enum RSVPState: String, Codable, Sendable, Hashable, CaseIterable {
    case attending = "ATTENDING"
    case maybe = "MAYBE"
    case declined = "DECLINED"
    case unsure = "UNSURE"
}

/// Whether someone can be reached right now: GraphQL's `Presence` on users, friends and chat messages.
/// The API shows the real value only to the person, their friends and admins; everyone else gets `offline`.
///
/// Decoding is case-insensitive, so it also reads the chat room's `presence` frames
/// (`{"type":"presence","user_id":"…","presence":"online"}`), and an unknown value decodes as `offline`.
public enum Presence: String, Codable, Sendable, Hashable, CaseIterable {
    /// Connected to a chat room now.
    case online = "ONLINE"
    /// Not in chat, but signed in on a device that gets push notifications.
    case push = "PUSH"
    /// Neither, or not for this viewer to see.
    case offline = "OFFLINE"

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Presence(rawValue: raw.uppercased()) ?? .offline
    }
}

// MARK: - Cover

/// What it costs to get into a venue on a night. Show ``totalCents``, the all-in price, and take it with
/// ``AudienceKitClient/buyCover(venueID:)`` when ``payable`` is true; otherwise it's paid at the door.
public struct CoverCharge: Codable, Sendable, Hashable {
    /// The cover the venue receives, in cents.
    public var amountCents: Int
    /// What the buyer pays, all in, in cents.
    public var totalCents: Int
    /// The Hot Mess fee in it, in cents.
    public var feeCents: Int
    /// An ISO 4217 code in lower case, e.g. `usd`.
    public var currency: String
    /// The night it is for, as `yyyy-MM-dd`. A night runs 6am to 6am, so 1am Saturday is Friday night.
    public var night: String
    /// When the cover starts, as `HH:MM` local time, e.g. `21:00`.
    public var from: String?
    /// Whether it can be paid in the app.
    public var payable: Bool
    /// The event that night, when it sets the night's cover.
    public var event: CoverEvent?
}

/// The event an ``Admission`` or ``CoverCharge`` is for.
public struct CoverEvent: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String?
}

/// The venue an ``Admission`` is for.
public struct CoverVenue: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String?
    public var photoUrl: String?
}

/// Where a cover payment stands. Unknown values from a newer API decode as ``unknown``.
public enum AdmissionStatus: String, Codable, Sendable, Hashable, CaseIterable {
    case pending = "PENDING"
    case paid = "PAID"
    case failed = "FAILED"
    case canceled = "CANCELED"
    case refunded = "REFUNDED"
    case disputed = "DISPUTED"
    case unknown

    public init(from decoder: any Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

/// Someone's cover for one night at a venue, and their pass. Make the pass's QR code with ``CoverPass``.
public struct Admission: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var status: AdmissionStatus
    /// The night, as `yyyy-MM-dd`.
    public var night: String
    /// The cover, in cents.
    public var amountCents: Int
    /// What the buyer paid, in cents.
    public var totalCents: Int
    public var currency: String
    /// Whether the buyer can refund it themselves: paid, not scanned in, and the night isn't over.
    public var isRefundable: Bool
    /// The Base64 key the pass QR code is made with. The buyer only.
    public var passSecret: String?
    /// How many times the door has scanned it.
    public var scanCount: Int
    /// When the door first scanned it, ISO 8601.
    public var checkedInAt: String?
    /// The buyer's name and profile photo, for the door.
    public var userName: String?
    public var userPhotoUrl: String?
    public var venue: CoverVenue?
    public var event: CoverEvent?
}

/// What ``AudienceKitClient/buyCover(venueID:)`` returns: the pending pass and what the venue's payment provider
/// needs. Stripe venues pay with Stripe's payment sheet; Square venues with Square's In-App Payments SDK.
public struct CoverPurchase: Codable, Sendable, Hashable {
    /// The pass, pending until the payment succeeds.
    public var admission: Admission
    /// `STRIPE` or `SQUARE`.
    public var provider: String
    /// Stripe: for the payment sheet; `nil` once it's paid.
    public var paymentIntentClientSecret: String?
    /// Stripe: the audience's publishable key.
    public var publishableKey: String?
    /// Stripe: the venue's connected account. Set it as the Stripe API client's `stripeAccount`.
    public var stripeAccountId: String?
    /// Square: the audience's application ID, for `SQIPInAppPaymentsSDK.squareApplicationID`.
    public var squareApplicationId: String?
    /// Square: the venue's location that gets paid.
    public var squareLocationId: String?

    public var isSquare: Bool { provider == "SQUARE" }
}

/// A venue's cover tonight and the signed-in user's pass for it.
public struct VenueCover: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String?
    /// The API's `cover` facet; nil when the venue takes no cover.
    private var cover: Facet?

    /// Tonight's cover, or `nil` when there is none.
    public var coverCharge: CoverCharge? {
        get { cover?.charge }
        set { cover = Facet(charge: newValue, viewerAdmission: cover?.viewerAdmission) }
    }
    /// The signed-in user's cover for tonight, paid or being paid.
    public var viewerAdmission: Admission? {
        get { cover?.viewerAdmission }
        set { cover = Facet(charge: cover?.charge, viewerAdmission: newValue) }
    }

    /// `cover { charge viewerAdmission }`.
    private struct Facet: Codable, Sendable, Hashable {
        var charge: CoverCharge?
        var viewerAdmission: Admission?
    }
}

/// A venue's door for one night.
public struct DoorNight: Codable, Sendable, Hashable {
    /// The night, as `yyyy-MM-dd`.
    public var night: String
    /// Covers paid and not refunded.
    public var paidCount: Int
    /// Paid covers scanned in.
    public var checkedInCount: Int
    /// Covers paid and not refunded, in cents, before fees.
    public var grossCents: Int
}

/// A venue whose door the signed-in user can work, with tonight's counts.
public struct DoorVenue: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String?
    public var photoUrl: String?
    /// The API's `cover` facet; nil when the venue takes no cover.
    private var cover: Facet?

    /// The night's door, or `nil` unless the signed-in user can work it.
    public var door: DoorNight? {
        get { cover?.door }
        set { cover = Facet(door: newValue) }
    }

    /// `cover { door }`.
    private struct Facet: Codable, Sendable, Hashable {
        var door: DoorNight?
    }
}

/// What the door should do with a scanned pass. Unknown values from a newer API decode as ``unknown``.
public enum ScanOutcome: String, Codable, Sendable, Hashable, CaseIterable {
    /// Paid and first scan tonight: let them in.
    case admit = "ADMIT"
    /// Paid and already scanned in tonight: coming back in.
    case reEntry = "RE_ENTRY"
    /// An old code, e.g. a screenshot.
    case expired = "EXPIRED"
    /// The cover wasn't paid, or was refunded or disputed.
    case notPaid = "NOT_PAID"
    /// A pass for another venue or another night.
    case wrongVenue = "WRONG_VENUE"
    /// Not a Hot Mess pass.
    case unreadable = "UNREADABLE"
    case unknown

    public init(from decoder: any Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

/// The answer to a door scan.
public struct ScanResult: Codable, Sendable, Hashable {
    public var outcome: ScanOutcome
    /// What to show the door, e.g. "Paid · Alex".
    public var message: String
    /// The pass, when the code was one the API knows.
    public var admission: Admission?
}
