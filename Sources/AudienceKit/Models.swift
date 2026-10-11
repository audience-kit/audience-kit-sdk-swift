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
    /// Its Google place ID (a city or region), when an admin has set one: the API's `profile { places { placeId } }`.
    public var googlePlaceId: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, label, cityNames, bannerUrl, profile
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        cityNames = try container.decodeIfPresent([String].self, forKey: .cityNames)
        bannerUrl = try container.decodeIfPresent(String.self, forKey: .bannerUrl)
        googlePlaceId = try container.decodeIfPresent(ListingProfile.self, forKey: .profile)?.places?.placeId
    }

    /// Writes the API's shape, so an encoded locale decodes back the same.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(label, forKey: .label)
        try container.encodeIfPresent(cityNames, forKey: .cityNames)
        try container.encodeIfPresent(bannerUrl, forKey: .bannerUrl)
        if let googlePlaceId {
            try container.encode(ListingProfile(places: .init(placeId: googlePlaceId)), forKey: .profile)
        }
    }
}

/// A venue, person or locale's `profile` facet, as far as the SDK reads it: the Facebook Page (`facebook { page }`)
/// and the Google place ID (`places { placeId }`). Either module may be left out of the query.
struct ListingProfile: Codable, Sendable, Hashable {
    struct Facebook: Codable, Sendable, Hashable { var page: Page? }
    struct Places: Codable, Sendable, Hashable { var placeId: String? }

    var facebook: Facebook?
    var places: Places?

    init(facebook: Facebook? = nil, places: Places? = nil) {
        self.facebook = facebook
        self.places = places
    }
}

/// A place: a Google place with a point.
public struct Location: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    /// The point as the API serializes it (WKT, e.g. `POINT (-122.42 37.77)`).
    public var point: String?
    /// Its Google place ID, when an admin or the researcher has set one: the API's `places { placeId }`.
    public var googlePlaceId: String?
    /// Its full address, when known.
    public var address: String?

    /// ``point`` parsed into latitude and longitude, when it is a WKT point.
    public var coordinate: Coordinate? { point.flatMap(Coordinate.init(wkt:)) }

    private enum CodingKeys: String, CodingKey {
        case id, point, address, places
    }

    public init(id: String, point: String? = nil, googlePlaceId: String? = nil, address: String? = nil) {
        self.id = id
        self.point = point
        self.googlePlaceId = googlePlaceId
        self.address = address
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        point = try container.decodeIfPresent(String.self, forKey: .point)
        address = try container.decodeIfPresent(String.self, forKey: .address)
        googlePlaceId = try container.decodeIfPresent(ListingProfile.Places.self, forKey: .places)?.placeId
    }

    /// Writes the API's shape, so an encoded location decodes back the same.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(point, forKey: .point)
        try container.encodeIfPresent(address, forKey: .address)
        if let googlePlaceId {
            try container.encode(ListingProfile.Places(placeId: googlePlaceId), forKey: .places)
        }
    }
}

/// A venue in the audience.
public struct Venue: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var hidden: Bool
    public var order: Int
    public var photoUrl: String?
    public var bannerUrl: String?
    /// Its Facebook Page, the API's `profile { facebook { page } }`; venues added without one have none.
    public var page: Page?
    public var locale: AudienceLocale
    public var location: Location?
    /// The audience's tags on it, by name; nil when the query didn't ask.
    public var tags: [Tag]?
    private var venueName: String?

    /// The venue's own name, falling back to its Facebook Page's.
    public var name: String { venueName ?? page?.name ?? "" }

    private enum CodingKeys: String, CodingKey {
        case id, hidden, order, photoUrl, bannerUrl, profile, locale, location, tags
        case venueName = "name"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        hidden = try container.decode(Bool.self, forKey: .hidden)
        order = try container.decode(Int.self, forKey: .order)
        photoUrl = try container.decodeIfPresent(String.self, forKey: .photoUrl)
        bannerUrl = try container.decodeIfPresent(String.self, forKey: .bannerUrl)
        page = try container.decodeIfPresent(ListingProfile.self, forKey: .profile)?.facebook?.page
        locale = try container.decode(AudienceLocale.self, forKey: .locale)
        location = try container.decodeIfPresent(Location.self, forKey: .location)
        tags = try container.decodeIfPresent([Tag].self, forKey: .tags)
        venueName = try container.decodeIfPresent(String.self, forKey: .venueName)
    }

    /// Writes the API's shape, so an encoded venue decodes back the same.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(hidden, forKey: .hidden)
        try container.encode(order, forKey: .order)
        try container.encodeIfPresent(photoUrl, forKey: .photoUrl)
        try container.encodeIfPresent(bannerUrl, forKey: .bannerUrl)
        if let page {
            try container.encode(ListingProfile(facebook: .init(page: page)), forKey: .profile)
        }
        try container.encode(locale, forKey: .locale)
        try container.encodeIfPresent(location, forKey: .location)
        try container.encodeIfPresent(tags, forKey: .tags)
        try container.encodeIfPresent(venueName, forKey: .venueName)
    }
}

/// A person (performer, promoter, DJ...) the audience follows.
public struct Person: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var order: Int
    public var global: Bool
    public var likeRequired: Bool
    /// Their Facebook Page, the API's `profile { facebook { page } }`; talent added by name has none yet.
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
        case id, order, global, likeRequired, profile, locales, tags, venues, events
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
        page = try container.decodeIfPresent(ListingProfile.self, forKey: .profile)?.facebook?.page
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
        if let page {
            try container.encode(ListingProfile(facebook: .init(page: page)), forKey: .profile)
        }
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
    /// The signed-in user's friends who have been there lately: the API's `friends { list }` facet. Nil when the
    /// query didn't ask.
    public var friends: [Friend]?

    public init(id: String, name: String? = nil, photoUrl: String? = nil, locale: AudienceLocale? = nil,
                friends: [Friend]? = nil) {
        self.id = id
        self.name = name
        self.photoUrl = photoUrl
        self.locale = locale
        self.friends = friends
    }

    private enum CodingKeys: String, CodingKey { case id, name, photoUrl, locale, friends }
    private struct FriendsFacet: Codable { var list: FriendList? }
    private struct FriendList: Codable { var nodes: [Friend?]? }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        photoUrl = try container.decodeIfPresent(String.self, forKey: .photoUrl)
        locale = try container.decodeIfPresent(AudienceLocale.self, forKey: .locale)
        friends = try container.decodeIfPresent(FriendsFacet.self, forKey: .friends)?.list?.nodes?.compactMap { $0 }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(photoUrl, forKey: .photoUrl)
        try container.encodeIfPresent(locale, forKey: .locale)
        try container.encodeIfPresent(friends.map { FriendsFacet(list: FriendList(nodes: $0)) }, forKey: .friends)
    }
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

/// Any record, as `node(id:)` returns it: its UUID and its GraphQL type.
public struct Node: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    /// The GraphQL type name, e.g. `Venue`.
    public var typename: String?

    enum CodingKeys: String, CodingKey {
        case id
        case typename = "__typename"
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
    /// The API's `tickets` facet, read for the `cover` facet inside it; nil where the audience has neither module.
    private var tickets: Tickets?

    /// Tonight's cover, or `nil` when there is none.
    public var coverCharge: CoverCharge? {
        get { tickets?.cover?.charge }
        set { tickets = Tickets(cover: Facet(charge: newValue, viewerAdmission: viewerAdmission)) }
    }
    /// The signed-in user's cover for tonight, paid or being paid.
    public var viewerAdmission: Admission? {
        get { tickets?.cover?.viewerAdmission }
        set { tickets = Tickets(cover: Facet(charge: coverCharge, viewerAdmission: newValue)) }
    }

    /// `tickets { cover }`.
    private struct Tickets: Codable, Sendable, Hashable {
        var cover: Facet?
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
    /// The API's `tickets` facet, read for the `cover` facet inside it.
    private var tickets: Tickets?

    /// The night's door, or `nil` unless the signed-in user can work it.
    public var door: DoorNight? {
        get { tickets?.cover?.door }
        set { tickets = Tickets(cover: Facet(door: newValue)) }
    }

    /// `tickets { cover }`.
    private struct Tickets: Codable, Sendable, Hashable {
        var cover: Facet?
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
