import AudienceCore
import Foundation

// The models the SDK's own operations decode into, shaped by the fields `Queries` selects (its fragments, one set per
// SDK version; the API contract is `AudienceKitSDK.apiVersion`). Every field is `let`, every type has a public
// memberwise initializer, and a field is optional where the schema says it is nullable or where the SDK's query may
// leave it out ("nil when the query didn't ask").

/// The audience a client is scoped to.
public struct Audience: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let subdomain: String
    /// Its look; nil when the query didn't ask.
    public let theme: AudienceTheme?

    public init(id: String, name: String, subdomain: String, theme: AudienceTheme? = nil) {
        self.id = id
        self.name = name
        self.subdomain = subdomain
        self.theme = theme
    }
}

/// An audience's look, as GraphQL returns it: a preset, a tagline and color token overrides.
public struct AudienceTheme: Codable, Sendable, Hashable {
    public let preset: String
    public let tagline: String?
    public let light: [ThemeToken]
    public let dark: [ThemeToken]

    public init(preset: String, tagline: String? = nil, light: [ThemeToken] = [], dark: [ThemeToken] = []) {
        self.preset = preset
        self.tagline = tagline
        self.light = light
        self.dark = dark
    }
}

/// One design-system color token, e.g. `accent` = `#b8236f`.
public struct ThemeToken: Codable, Sendable, Hashable {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// The Facebook page behind a venue or person: its name and pictures.
public struct Page: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    /// Profile picture, as the API sends it. Use ``AudienceKitClient/url(for:)`` to resolve relative paths.
    public let photoUrl: String?
    public let bannerUrl: String?

    public init(id: String, name: String, photoUrl: String? = nil, bannerUrl: String? = nil) {
        self.id = id
        self.name = name
        self.photoUrl = photoUrl
        self.bannerUrl = bannerUrl
    }
}

/// A city or region the audience is active in.
public struct AudienceLocale: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String?
    public let label: String?
    /// The cities it covers; nil when the query didn't ask.
    public let cityNames: [String]?
    public let bannerUrl: String?
    /// Its Google place ID (a city or region), when an admin has set one: the API's `profile { places { placeId } }`.
    public let googlePlaceId: String?

    public init(id: String, name: String? = nil, label: String? = nil, cityNames: [String]? = nil,
                bannerUrl: String? = nil, googlePlaceId: String? = nil)
    {
        self.id = id
        self.name = name
        self.label = label
        self.cityNames = cityNames
        self.bannerUrl = bannerUrl
        self.googlePlaceId = googlePlaceId
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, label, cityNames, bannerUrl, profile
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        cityNames = try container.decodeIfPresent([String].self, forKey: .cityNames)
        bannerUrl = try container.decodeIfPresent(String.self, forKey: .bannerUrl)
        googlePlaceId = try container.decodeIfPresent(ListingProfile.self, forKey: .profile)?.places?.placeId
    }

    /// Writes the API's shape, so an encoded locale decodes back the same.
    public func encode(to encoder: any Encoder) throws {
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

/// A venue, person or locale's `profile` mixin, as far as the SDK reads it: the Facebook Page (`facebook { page }`)
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
    public let id: String
    /// Where it is: the API's `point` (a `Geography`, WKT on the wire) as latitude and longitude. Nil when the place
    /// has no point, or the point isn't one (a boundary, say).
    public let coordinate: Coordinate?
    /// Its Google place ID, when an admin or the researcher has set one: the API's `places { placeId }`.
    public let googlePlaceId: String?
    /// Its full address, when known.
    public let address: String?

    private enum CodingKeys: String, CodingKey {
        case id, point, address, places
    }

    public init(id: String, coordinate: Coordinate? = nil, googlePlaceId: String? = nil, address: String? = nil) {
        self.id = id
        self.coordinate = coordinate
        self.googlePlaceId = googlePlaceId
        self.address = address
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        coordinate = try container.decodeIfPresent(String.self, forKey: .point).flatMap(Coordinate.init(wkt:))
        address = try container.decodeIfPresent(String.self, forKey: .address)
        googlePlaceId = try container.decodeIfPresent(ListingProfile.Places.self, forKey: .places)?.placeId
    }

    /// Writes the API's shape, so an encoded location decodes back the same.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(coordinate?.wkt, forKey: .point)
        try container.encodeIfPresent(address, forKey: .address)
        if let googlePlaceId {
            try container.encode(ListingProfile.Places(placeId: googlePlaceId), forKey: .places)
        }
    }
}

/// A venue in the audience.
public struct Venue: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let hidden: Bool
    public let order: Int
    public let photoUrl: String?
    public let bannerUrl: String?
    /// Its Facebook Page, the API's `profile { facebook { page } }`; venues added without one have none.
    public let page: Page?
    public let locale: AudienceLocale
    public let location: Location?
    /// The audience's tags on it, by name; nil when the query didn't ask.
    public let tags: [Tag]?
    private let venueName: String?

    /// The venue's own name, falling back to its Facebook Page's.
    public var name: String { venueName ?? page?.name ?? "" }

    /// `name` is the venue's own name (the API's `name`, nullable); ``name`` falls back to the Page's.
    public init(id: String, name: String? = nil, hidden: Bool = false, order: Int = 0, photoUrl: String? = nil,
                bannerUrl: String? = nil, page: Page? = nil, locale: AudienceLocale, location: Location? = nil,
                tags: [Tag]? = nil)
    {
        self.id = id
        self.venueName = name
        self.hidden = hidden
        self.order = order
        self.photoUrl = photoUrl
        self.bannerUrl = bannerUrl
        self.page = page
        self.locale = locale
        self.location = location
        self.tags = tags
    }

    private enum CodingKeys: String, CodingKey {
        case id, hidden, order, photoUrl, bannerUrl, profile, locale, location, tags
        case venueName = "name"
    }

    public init(from decoder: any Decoder) throws {
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
    public func encode(to encoder: any Encoder) throws {
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
    public let id: String
    public let avatarUrl: String?
    public let bannerUrl: String?
    public let order: Int
    public let global: Bool
    public let likeRequired: Bool
    /// Their Facebook Page, the API's `profile { facebook { page } }`; talent added by name has none yet.
    public let page: Page?
    /// The venue they are based at, if any: the API's `venues { home }`.
    public let homeVenue: PersonVenue?
    /// The locales they're featured in; nil when the query didn't ask.
    public let locales: [AudienceLocale]?
    /// Upcoming events they host or play and those of the troupes they're in, soonest first: the API's
    /// `events { upcoming }`, or the nodes of `events { involvements }`; nil when the query asked for neither.
    public let events: [PersonEvent]?
    /// The same events as `events`, with how they're on each: themselves, or through a troupe (`via`); nil when the
    /// query didn't ask.
    public let eventInvolvements: [PersonEventInvolvement]?
    /// The audience's tags on them, by name; nil when the query didn't ask.
    public let tags: [Tag]?
    private let personName: String?

    /// Their name as the audience shows it, falling back to their Facebook Page's.
    public var name: String { personName ?? page?.name ?? "" }

    /// `name` is their own name (the API's `name`, nullable); ``name`` falls back to the Page's.
    public init(id: String, name: String? = nil, order: Int = 0, global: Bool = false, likeRequired: Bool = false,
                page: Page? = nil, homeVenue: PersonVenue? = nil, locales: [AudienceLocale]? = nil,
                events: [PersonEvent]? = nil, eventInvolvements: [PersonEventInvolvement]? = nil, tags: [Tag]? = nil,
                avatarUrl: String? = nil, bannerUrl: String? = nil)
    {
        self.id = id
        self.avatarUrl = avatarUrl
        self.bannerUrl = bannerUrl
        self.personName = name
        self.order = order
        self.global = global
        self.likeRequired = likeRequired
        self.page = page
        self.homeVenue = homeVenue
        self.locales = locales
        self.events = events
        self.eventInvolvements = eventInvolvements
        self.tags = tags
    }

    private enum CodingKeys: String, CodingKey {
        case id, avatarUrl, bannerUrl, order, global, likeRequired, profile, locales, tags, venues, events
        case personName = "name"
    }

    /// The API's `venues` mixin.
    private enum VenuesKeys: String, CodingKey { case home }
    /// The API's `events` mixin: two connections.
    private enum EventsKeys: String, CodingKey { case upcoming, involvements }
    private enum ConnectionKeys: String, CodingKey { case nodes, edges }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        avatarUrl = try container.decodeIfPresent(String.self, forKey: .avatarUrl)
        bannerUrl = try container.decodeIfPresent(String.self, forKey: .bannerUrl)
        order = try container.decode(Int.self, forKey: .order)
        global = try container.decode(Bool.self, forKey: .global)
        likeRequired = try container.decode(Bool.self, forKey: .likeRequired)
        page = try container.decodeIfPresent(ListingProfile.self, forKey: .profile)?.facebook?.page
        homeVenue = try container.decodeIfPresent(VenuesMixin.self, forKey: .venues)?.home
        locales = try container.decodeIfPresent([AudienceLocale].self, forKey: .locales)
        let eventsMixin = try container.decodeIfPresent(EventsMixin.self, forKey: .events)
        let involvements = eventsMixin?.involvements?.edges
        eventInvolvements = involvements
        // `Queries.people` asks for the involvements alone: their nodes are the events.
        events = eventsMixin?.upcoming?.nodes ?? involvements?.map(\.event)
        tags = try container.decodeIfPresent([Tag].self, forKey: .tags)
        personName = try container.decodeIfPresent(String.self, forKey: .personName)
    }

    /// Writes the API's shape, so an encoded person decodes back the same.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(avatarUrl, forKey: .avatarUrl)
        try container.encodeIfPresent(bannerUrl, forKey: .bannerUrl)
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
        if events != nil || eventInvolvements != nil {
            var eventsMixin = container.nestedContainer(keyedBy: EventsKeys.self, forKey: .events)
            if let events {
                var upcoming = eventsMixin.nestedContainer(keyedBy: ConnectionKeys.self, forKey: .upcoming)
                try upcoming.encode(events, forKey: .nodes)
            }
            if let eventInvolvements {
                var connection = eventsMixin.nestedContainer(keyedBy: ConnectionKeys.self, forKey: .involvements)
                try connection.encode(eventInvolvements, forKey: .edges)
            }
        }
    }

    /// `venues { home }`.
    private struct VenuesMixin: Decodable {
        var home: PersonVenue?
    }

    /// `events { upcoming { nodes } involvements { edges } }`, either of which the query may leave out.
    private struct EventsMixin: Decodable {
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

        init(from decoder: any Decoder) throws {
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

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nodes = try container.decodeIfPresent([Item?].self, forKey: .nodes)?.compactMap { $0 }
    }
}

/// How a person is on one of their upcoming events: themselves, or through a troupe they're in.
public struct PersonEventInvolvement: Codable, Sendable, Hashable, Identifiable {
    /// GraphQL's `PersonEventRelationship`. A value this SDK doesn't know decodes as ``unknown(_:)``.
    public enum Relationship: Sendable, Hashable, RawRepresentable, Codable {
        /// They host or play it themselves.
        case direct
        /// A troupe they're in hosts or plays it.
        case troupe
        case unknown(String)

        /// The relationships this SDK knows.
        public static let known: [Relationship] = [.direct, .troupe]

        public init(rawValue: String) {
            switch rawValue.uppercased() {
            case "DIRECT": self = .direct
            case "TROUPE": self = .troupe
            default: self = .unknown(rawValue)
            }
        }

        public var rawValue: String {
            switch self {
            case .direct: "DIRECT"
            case .troupe: "TROUPE"
            case let .unknown(value): value
            }
        }

        public init(from decoder: any Decoder) throws {
            self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    /// The troupe an event comes through.
    public struct Troupe: Codable, Sendable, Hashable, Identifiable {
        public let id: String
        public let name: String?

        public init(id: String, name: String? = nil) {
            self.id = id
            self.name = name
        }
    }

    public let event: PersonEvent
    public let relationship: Relationship
    /// Their role on it, like host or performer: the troupe's when it's through one.
    public let role: String?
    /// The troupe it comes through, for showing "with <troupe>"; nil when it's their own.
    public let via: Troupe?

    public var id: String { event.id }

    public init(event: PersonEvent, relationship: Relationship = .direct, role: String? = nil, via: Troupe? = nil) {
        self.event = event
        self.relationship = relationship
        self.role = role
        self.via = via
    }

    private enum CodingKeys: String, CodingKey {
        case event = "node", relationship, role, via
    }
}

/// A venue as a person's home venue or gig carries it.
public struct PersonVenue: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String?
    public let photoUrl: String?
    public let locale: AudienceLocale?
    /// The signed-in user's friends who have been there lately: the API's `friends { list }` mixin. Nil when the
    /// query didn't ask.
    public let friends: [Friend]?

    public init(id: String, name: String? = nil, photoUrl: String? = nil, locale: AudienceLocale? = nil,
                friends: [Friend]? = nil)
    {
        self.id = id
        self.name = name
        self.photoUrl = photoUrl
        self.locale = locale
        self.friends = friends
    }

    private enum CodingKeys: String, CodingKey { case id, name, photoUrl, locale, friends }
    private struct FriendsMixin: Codable { var list: FriendList? }
    private struct FriendList: Codable { var nodes: [Friend?]? }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        photoUrl = try container.decodeIfPresent(String.self, forKey: .photoUrl)
        locale = try container.decodeIfPresent(AudienceLocale.self, forKey: .locale)
        friends = try container.decodeIfPresent(FriendsMixin.self, forKey: .friends)?.list?.nodes?.compactMap { $0 }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(photoUrl, forKey: .photoUrl)
        try container.encodeIfPresent(locale, forKey: .locale)
        try container.encodeIfPresent(friends.map { FriendsMixin(list: FriendList(nodes: $0)) }, forKey: .friends)
    }
}

/// One of a person's upcoming events.
public struct PersonEvent: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String?
    /// When it starts; nil when not scheduled yet, or when the query didn't ask.
    public let startAt: Date?
    /// Its venue's locale, or its series' while the venue is still to be announced.
    public let locale: AudienceLocale?
    /// The audience's tags on it, by name; nil when the query didn't ask.
    public let tags: [Tag]?
    /// The API's `venue` mixin: a display name and the venue, if any.
    private let venueMixin: VenueMixin?

    /// Where it is; nil while the venue is still to be announced, or when the query didn't ask.
    public var venue: PersonVenue? { venueMixin?.venue }

    /// Its venue's name as the API shows it, e.g. "To be announced" when there is none; nil when the query didn't ask.
    public var venueName: String? { venueMixin?.name }

    public init(id: String, name: String? = nil, startAt: Date? = nil, locale: AudienceLocale? = nil,
                venue: PersonVenue? = nil, venueName: String? = nil, tags: [Tag]? = nil)
    {
        self.id = id
        self.name = name
        self.startAt = startAt
        self.locale = locale
        self.tags = tags
        venueMixin = venue == nil && venueName == nil ? nil : VenueMixin(name: venueName, venue: venue)
    }

    private struct VenueMixin: Codable, Sendable, Hashable {
        var name: String?
        var venue: PersonVenue?
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, startAt, locale, tags
        case venueMixin = "venue"
    }

    /// Reads `startAt` as the ISO 8601 string the API sends, whatever the decoder's date strategy.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        startAt = try container.decodeISO8601IfPresent(forKey: .startAt)
        locale = try container.decodeIfPresent(AudienceLocale.self, forKey: .locale)
        tags = try container.decodeIfPresent([Tag].self, forKey: .tags)
        venueMixin = try container.decodeIfPresent(VenueMixin.self, forKey: .venueMixin)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(startAt.map(ISO8601.string(from:)), forKey: .startAt)
        try container.encodeIfPresent(locale, forKey: .locale)
        try container.encodeIfPresent(tags, forKey: .tags)
        try container.encodeIfPresent(venueMixin, forKey: .venueMixin)
    }
}

extension KeyedDecodingContainer {
    /// An `ISO8601DateTime` field: a string, parsed whatever the decoder's date strategy; nil when null or absent.
    func decodeISO8601IfPresent(forKey key: Key) throws -> Date? {
        guard let text = try decodeIfPresent(String.self, forKey: key) else { return nil }
        guard let date = ISO8601.date(from: text) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self,
                                                   debugDescription: "\(text) isn't an ISO 8601 date")
        }
        return date
    }
}

/// One of the audience's own labels, like "Drag" or "Resident DJ", on its people, events and venues.
public struct Tag: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    /// A `#rrggbb` color for its chip, or nil for the theme's accent.
    public let color: String?
    /// Whether people can identify with it (see ``TribeIdentification``); nil when the query didn't ask.
    public let tribe: Bool?

    public init(id: String, name: String, color: String? = nil, tribe: Bool? = nil) {
        self.id = id
        self.name = name
        self.color = color
        self.tribe = tribe
    }
}

/// Someone identifying with one of the audience's tribes. A private one may be sensitive (HIV status, say): the API
/// only ever shows it to them and to people in the same tribe, and apps should keep it discreet.
public struct TribeIdentification: Codable, Sendable, Hashable {
    public let tag: Tag
    public let isPrivate: Bool

    public init(tag: Tag, isPrivate: Bool) {
        self.tag = tag
        self.isPrivate = isPrivate
    }
}

/// The tribes people can identify with in an audience, and which of them the signed-in user has.
public struct Tribes: Sendable, Hashable {
    public let available: [Tag]
    public let mine: [TribeIdentification]

    public init(available: [Tag], mine: [TribeIdentification]) {
        self.available = available
        self.mine = mine
    }
}

/// One of the signed-in user's friends.
public struct Friend: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String?
    public let facebookId: String?
    /// Whether they can be reached now; nil when the query didn't ask.
    public let presence: Presence?

    public init(id: String, name: String? = nil, facebookId: String? = nil, presence: Presence? = nil) {
        self.id = id
        self.name = name
        self.facebookId = facebookId
        self.presence = presence
    }
}

/// The signed-in user's own profile (`me { self }`, a SelfUser): what only they see as well as their public fields.
public struct SelfUser: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String?
    public let firstName: String?
    public let lastName: String?
    public let emailAddress: String?
    /// Nil when the query didn't ask.
    public let isAdmin: Bool?
    /// Whether they can be reached now; nil when the query didn't ask.
    public let presence: Presence?

    public init(id: String, name: String? = nil, firstName: String? = nil, lastName: String? = nil,
                emailAddress: String? = nil, isAdmin: Bool? = nil, presence: Presence? = nil)
    {
        self.id = id
        self.name = name
        self.firstName = firstName
        self.lastName = lastName
        self.emailAddress = emailAddress
        self.isAdmin = isAdmin
        self.presence = presence
    }
}

/// Any record, as `node(id:)` returns it: its UUID and its GraphQL type.
public struct Node: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    /// The GraphQL type name, e.g. `Venue`.
    public let typename: String?

    public init(id: String, typename: String? = nil) {
        self.id = id
        self.typename = typename
    }

    enum CodingKeys: String, CodingKey {
        case id
        case typename = "__typename"
    }
}

/// Whether the signed-in user is going to an event: GraphQL's `RSVPState`. A value this SDK doesn't know decodes as
/// ``unknown(_:)``, and is sent back as is.
public enum RSVPState: Sendable, Hashable, RawRepresentable, Codable {
    case attending
    case maybe
    case declined
    case unsure
    case unknown(String)

    /// The states this SDK knows.
    public static let known: [RSVPState] = [.attending, .maybe, .declined, .unsure]

    public init(rawValue: String) {
        switch rawValue.uppercased() {
        case "ATTENDING": self = .attending
        case "MAYBE": self = .maybe
        case "DECLINED": self = .declined
        case "UNSURE": self = .unsure
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .attending: "ATTENDING"
        case .maybe: "MAYBE"
        case .declined: "DECLINED"
        case .unsure: "UNSURE"
        case let .unknown(value): value
        }
    }

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Whether someone can be reached right now: GraphQL's `Presence` on users, friends and chat messages.
/// The API shows the real value only to the person, their friends and admins; everyone else gets `offline`.
///
/// Decoding is case-insensitive, so it also reads the chat room's `presence` frames
/// (`{"type":"presence","user_id":"…","presence":"online"}`). A value this SDK doesn't know decodes as
/// ``unknown(_:)``; treat it as not reachable.
public enum Presence: Sendable, Hashable, RawRepresentable, Codable {
    /// Connected to a chat room now.
    case online
    /// Not in chat, but signed in on a device that gets push notifications.
    case push
    /// Neither, or not for this viewer to see.
    case offline
    case unknown(String)

    /// The presences this SDK knows.
    public static let known: [Presence] = [.online, .push, .offline]

    public init(rawValue: String) {
        switch rawValue.uppercased() {
        case "ONLINE": self = .online
        case "PUSH": self = .push
        case "OFFLINE": self = .offline
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .online: "ONLINE"
        case .push: "PUSH"
        case .offline: "OFFLINE"
        case let .unknown(value): value
        }
    }

    /// Whether they can be reached at all: in chat or by push.
    public var isReachable: Bool { self == .online || self == .push }

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - Cover

/// An amount of money as the API sends it (GraphQL's `Money`): the minor unit and the currency, never a float.
public struct Money: Codable, Sendable, Hashable {
    /// The amount in the currency's minor unit (cents for dollars).
    public let cents: Int
    /// Its ISO 4217 code in lower case, e.g. `usd`.
    public let currency: String

    public init(cents: Int, currency: String) {
        self.cents = cents
        self.currency = currency
    }
}

/// Someone as other people see them (GraphQL's `Profile`): the buyer on an ``Admission``, for the door.
public struct Profile: Codable, Sendable, Hashable, Identifiable {
    /// The user's ID, the same as their `User`'s.
    public let id: String
    /// Their display name: in full for themself, their friends and the audience's staff; first name and last
    /// initial ("Aurora B.") for anyone else.
    public let name: String
    /// Their profile picture, as the API sends it. Use ``AudienceKitClient/url(for:)`` to resolve relative paths.
    public let avatarUrl: String?

    public init(id: String, name: String, avatarUrl: String? = nil) {
        self.id = id
        self.name = name
        self.avatarUrl = avatarUrl
    }
}

/// What it costs to get into a venue on a night. Show ``total``, the all-in price, and take it with
/// ``AudienceKitClient/buyCover(venueID:)`` when ``payable`` is true; otherwise it's paid at the door.
public struct CoverCharge: Codable, Sendable, Hashable {
    /// The cover the venue receives.
    public let amount: Money
    /// The audience's fee in it; ``AudienceKitConfiguration/feeLabel`` names it for the person.
    public let fee: Money
    /// What the buyer pays, all in.
    public let total: Money
    /// The night it is for, as `yyyy-MM-dd`. A night runs 6am to 6am, so 1am Saturday is Friday night.
    public let night: String
    /// When the cover starts, as `HH:MM` local time, e.g. `21:00`.
    public let from: String?
    /// Whether it can be paid in the app.
    public let payable: Bool
    /// The event that night, when it sets the night's cover.
    public let event: CoverEvent?

    public init(amount: Money, fee: Money, total: Money, night: String, from: String? = nil, payable: Bool,
                event: CoverEvent? = nil)
    {
        self.amount = amount
        self.fee = fee
        self.total = total
        self.night = night
        self.from = from
        self.payable = payable
        self.event = event
    }
}

/// The event an ``Admission`` or ``CoverCharge`` is for.
public struct CoverEvent: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String?

    public init(id: String, name: String? = nil) {
        self.id = id
        self.name = name
    }
}

/// The venue an ``Admission`` is for.
public struct CoverVenue: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String?
    public let photoUrl: String?

    public init(id: String, name: String? = nil, photoUrl: String? = nil) {
        self.id = id
        self.name = name
        self.photoUrl = photoUrl
    }
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
    public let id: String
    public let status: AdmissionStatus
    /// The night, as `yyyy-MM-dd`.
    public let night: String
    /// The cover.
    public let amount: Money
    /// What the buyer paid.
    public let total: Money
    /// Whether the buyer can refund it themselves: paid, not scanned in, and the night isn't over.
    public let isRefundable: Bool
    /// The Base64 key the pass QR code is made with. The buyer only.
    public let passSecret: String?
    /// How many times the door has scanned it.
    public let scanCount: Int
    /// When the door first scanned it.
    public let checkedInAt: Date?
    /// The buyer: their name for the door, their picture so the door can match faces.
    public let profile: Profile
    public let venue: CoverVenue
    public let event: CoverEvent?

    public init(id: String, status: AdmissionStatus, night: String, amount: Money, total: Money,
                isRefundable: Bool = false, passSecret: String? = nil, scanCount: Int = 0, checkedInAt: Date? = nil,
                profile: Profile, venue: CoverVenue, event: CoverEvent? = nil)
    {
        self.id = id
        self.status = status
        self.night = night
        self.amount = amount
        self.total = total
        self.isRefundable = isRefundable
        self.passSecret = passSecret
        self.scanCount = scanCount
        self.checkedInAt = checkedInAt
        self.profile = profile
        self.venue = venue
        self.event = event
    }

    private enum CodingKeys: String, CodingKey {
        case id, status, night, amount, total, isRefundable, passSecret, scanCount, checkedInAt, profile, venue, event
    }

    /// Reads `checkedInAt` as the ISO 8601 string the API sends, whatever the decoder's date strategy.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        status = try container.decode(AdmissionStatus.self, forKey: .status)
        night = try container.decode(String.self, forKey: .night)
        amount = try container.decode(Money.self, forKey: .amount)
        total = try container.decode(Money.self, forKey: .total)
        isRefundable = try container.decode(Bool.self, forKey: .isRefundable)
        passSecret = try container.decodeIfPresent(String.self, forKey: .passSecret)
        scanCount = try container.decode(Int.self, forKey: .scanCount)
        checkedInAt = try container.decodeISO8601IfPresent(forKey: .checkedInAt)
        profile = try container.decode(Profile.self, forKey: .profile)
        venue = try container.decode(CoverVenue.self, forKey: .venue)
        event = try container.decodeIfPresent(CoverEvent.self, forKey: .event)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(status, forKey: .status)
        try container.encode(night, forKey: .night)
        try container.encode(amount, forKey: .amount)
        try container.encode(total, forKey: .total)
        try container.encode(isRefundable, forKey: .isRefundable)
        try container.encodeIfPresent(passSecret, forKey: .passSecret)
        try container.encode(scanCount, forKey: .scanCount)
        try container.encodeIfPresent(checkedInAt.map(ISO8601.string(from:)), forKey: .checkedInAt)
        try container.encode(profile, forKey: .profile)
        try container.encode(venue, forKey: .venue)
        try container.encodeIfPresent(event, forKey: .event)
    }
}

/// Who takes a venue's cover payments: GraphQL's `PaymentProvider`. A value this SDK doesn't know decodes as
/// ``unknown(_:)``; the app can't pay it and should say so.
public enum PaymentProvider: Sendable, Hashable, RawRepresentable, Codable {
    /// Stripe Connect: pay with Stripe's payment sheet.
    case stripe
    /// Square: pay with Square's In-App Payments SDK.
    case square
    case unknown(String)

    /// The providers this SDK knows.
    public static let known: [PaymentProvider] = [.stripe, .square]

    public init(rawValue: String) {
        switch rawValue.uppercased() {
        case "STRIPE": self = .stripe
        case "SQUARE": self = .square
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .stripe: "STRIPE"
        case .square: "SQUARE"
        case let .unknown(value): value
        }
    }

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// What ``AudienceKitClient/buyCover(venueID:)`` returns: the pending pass and what the venue's payment provider
/// needs. Stripe venues pay with Stripe's payment sheet; Square venues with Square's In-App Payments SDK.
public struct CoverPurchase: Codable, Sendable, Hashable {
    /// The pass, pending until the payment succeeds.
    public let admission: Admission
    /// Who takes the payment.
    public let provider: PaymentProvider
    /// Stripe: for the payment sheet; `nil` once it's paid.
    public let paymentIntentClientSecret: String?
    /// Stripe: the audience's publishable key.
    public let publishableKey: String?
    /// Stripe: the venue's connected account. Set it as the Stripe API client's `stripeAccount`.
    public let stripeAccountId: String?
    /// Square: the audience's application ID, for `SQIPInAppPaymentsSDK.squareApplicationID`.
    public let squareApplicationId: String?
    /// Square: the venue's location that gets paid.
    public let squareLocationId: String?

    public var isSquare: Bool { provider == .square }

    public init(admission: Admission, provider: PaymentProvider, paymentIntentClientSecret: String? = nil,
                publishableKey: String? = nil, stripeAccountId: String? = nil, squareApplicationId: String? = nil,
                squareLocationId: String? = nil)
    {
        self.admission = admission
        self.provider = provider
        self.paymentIntentClientSecret = paymentIntentClientSecret
        self.publishableKey = publishableKey
        self.stripeAccountId = stripeAccountId
        self.squareApplicationId = squareApplicationId
        self.squareLocationId = squareLocationId
    }
}

/// A venue's cover tonight and the signed-in user's pass for it.
public struct VenueCover: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String?
    /// The API's `tickets` mixin, read for the `cover` mixin inside it; nil where the audience has neither module.
    private let tickets: Tickets?

    /// Tonight's cover, or `nil` when there is none.
    public var coverCharge: CoverCharge? { tickets?.cover?.charge }
    /// The signed-in user's cover for tonight, paid or being paid.
    public var viewerAdmission: Admission? { tickets?.cover?.viewerAdmission }

    public init(id: String, name: String? = nil, coverCharge: CoverCharge? = nil, viewerAdmission: Admission? = nil) {
        self.id = id
        self.name = name
        tickets = Tickets(cover: Mixin(charge: coverCharge, viewerAdmission: viewerAdmission))
    }

    /// `tickets { cover }`.
    private struct Tickets: Codable, Sendable, Hashable {
        var cover: Mixin?
    }

    /// `cover { charge viewerAdmission }`.
    private struct Mixin: Codable, Sendable, Hashable {
        var charge: CoverCharge?
        var viewerAdmission: Admission?
    }
}

/// A venue's door for one night.
public struct DoorNight: Codable, Sendable, Hashable {
    /// The night, as `yyyy-MM-dd`.
    public let night: String
    /// Covers paid and not refunded.
    public let paidCount: Int
    /// Paid covers scanned in.
    public let checkedInCount: Int
    /// Covers paid and not refunded, before fees.
    public let gross: Money

    public init(night: String, paidCount: Int, checkedInCount: Int, gross: Money) {
        self.night = night
        self.paidCount = paidCount
        self.checkedInCount = checkedInCount
        self.gross = gross
    }
}

/// A venue whose door the signed-in user can work, with tonight's counts.
public struct DoorVenue: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String?
    public let photoUrl: String?
    /// The API's `tickets` mixin, read for the `cover` mixin inside it.
    private let tickets: Tickets?

    /// The night's door, or `nil` unless the signed-in user can work it.
    public var door: DoorNight? { tickets?.cover?.door }

    public init(id: String, name: String? = nil, photoUrl: String? = nil, door: DoorNight? = nil) {
        self.id = id
        self.name = name
        self.photoUrl = photoUrl
        tickets = Tickets(cover: Mixin(door: door))
    }

    /// `tickets { cover }`.
    private struct Tickets: Codable, Sendable, Hashable {
        var cover: Mixin?
    }

    /// `cover { door }`.
    private struct Mixin: Codable, Sendable, Hashable {
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
    /// Not a pass of this audience's.
    case unreadable = "UNREADABLE"
    case unknown

    public init(from decoder: any Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

/// The answer to a door scan.
public struct ScanResult: Codable, Sendable, Hashable {
    public let outcome: ScanOutcome
    /// What to show the door, e.g. "Paid · Alex".
    public let message: String
    /// The pass, when the code was one the API knows.
    public let admission: Admission?

    public init(outcome: ScanOutcome, message: String, admission: Admission? = nil) {
        self.outcome = outcome
        self.message = message
        self.admission = admission
    }
}
