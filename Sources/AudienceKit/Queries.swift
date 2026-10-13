import AudienceCore
import Foundation

/// The GraphQL documents behind the client's typed helpers: this SDK version's fragments, which the models in
/// `Models.swift` decode. Internal: apps run their own operations through `AudienceSession.graphQL` and decode into
/// their own models.
enum Queries {
    static let pageFields = "id name photoUrl bannerUrl"
    static let localeFields = "id name label cityNames bannerUrl profile { places { placeId } }"
    /// A tag on a venue, person or event: its name and chip color.
    static let tagFields = "id name color"
    /// A person's home venue or gig venue: where it is, and which of the signed-in user's
    /// friends are there now.
    static let personVenueFields = "id name photoUrl locale { id name } friends { list { nodes { id name facebookId presence } } }"
    /// One of a person's events (`PersonEvent`), on its own or as the node of a `PersonEventInvolvement`. Its
    /// `venue` is the events mixin: a display name ("To be announced" when there is none) and the venue, if any.
    static let personEventFields = "id name startAt locale { id name } venue { name venue { \(personVenueFields) } } tags { \(tagFields) }"

    static let audience = """
    query Audience {
      id name subdomain theme { preset tagline light { name value } dark { name value } }
    }
    """

    static let venues = """
    query Venues {
      venues {
        list {
          nodes {
            id name hidden order photoUrl bannerUrl
            profile { facebook { page { \(pageFields) } } }
            locale { \(localeFields) }
            location { id point address places { placeId } }
            tags { \(tagFields) }
          }
        }
      }
    }
    """

    static let people = """
    query People {
      people {
        list {
          nodes {
            id name avatarUrl bannerUrl order global likeRequired profile { facebook { page { \(pageFields) } } }
            venues { home { \(personVenueFields) } }
            locales { id name }
            events { involvements { edges { relationship role via { id name } node { \(personEventFields) } } } }
            tags { \(tagFields) }
          }
        }
      }
    }
    """

    static let locales = """
    query Locales {
      locales { \(localeFields) }
    }
    """

    static let me = """
    query Me {
      me { self { id name firstName lastName emailAddress isAdmin presence } }
    }
    """

    static let closestLocale = """
    query ClosestLocale($near: CoordinatesInput!) {
      closestLocale(near: $near) { \(localeFields) }
    }
    """

    static let rsvpEvent = """
    mutation RSVPEvent($eventId: ID!, $state: RSVPState!) {
      rsvpEvent(input: { eventId: $eventId, state: $state }) { event { id rsvp { mine } } }
    }
    """

    /// The tribes people can identify with here, and the signed-in user's own.
    static let tribes = """
    query Tribes {
      id tribes { \(tagFields) tribe }
      me { self { id tribes { isPrivate tag { \(tagFields) tribe } } } }
    }
    """

    static let identifyWithTribe = """
    mutation IdentifyWithTribe($tagId: ID!, $isPrivate: Boolean) {
      identifyWithTribe(input: { tagId: $tagId, isPrivate: $isPrivate }) {
        tribes { isPrivate tag { \(tagFields) tribe } }
      }
    }
    """

    static let leaveTribe = """
    mutation LeaveTribe($tagId: ID!) {
      leaveTribe(input: { tagId: $tagId }) { tribes { isPrivate tag { \(tagFields) tribe } } }
    }
    """

    static let registerDevice = """
    mutation RegisterDevice($notificationToken: String!, $appId: String, $sandbox: Boolean) {
      registerDevice(input: { notificationToken: $notificationToken, appId: $appId, sandbox: $sandbox }) { registered }
    }
    """

    /// A ``Money``.
    static let moneyFields = "cents currency"
    /// A ``CoverCharge``.
    static let coverChargeFields = """
    amount { \(moneyFields) } fee { \(moneyFields) } total { \(moneyFields) } night from payable event { id name }
    """
    /// An ``Admission``: the pass secret the buyer makes the QR code from, and the buyer's ``Profile`` for the door.
    static let admissionFields = """
    id status night amount { \(moneyFields) } total { \(moneyFields) } isRefundable passSecret scanCount checkedInAt \
    profile { id name avatarUrl } venue { id name photoUrl } event { id name }
    """
    static let doorNightFields = "night paidCount checkedInCount gross { \(moneyFields) }"

    static let venueCover = """
    query VenueCover($id: ID!) {
      venues {
        venue(id: $id) {
          id name
          tickets {
            cover {
              charge { \(coverChargeFields) }
              viewerAdmission { \(admissionFields) }
            }
          }
        }
      }
    }
    """

    static let admissions = """
    query Admissions {
      me { cover { admissions { nodes { \(admissionFields) } } } }
    }
    """

    /// Staff work: sent to ``GraphQLEndpoint/staff``.
    static let doorVenues = """
    # endpoint: staff
    query DoorVenues {
      me { cover { doorVenues { nodes { id name photoUrl tickets { cover { door { \(doorNightFields) } } } } } } }
    }
    """

    /// Staff work: sent to ``GraphQLEndpoint/staff``.
    static let venueDoor = """
    # endpoint: staff
    query VenueDoor($id: ID!, $night: ISO8601Date) {
      venues { venue(id: $id) { id name photoUrl tickets { cover { door(night: $night) { \(doorNightFields) } } } } }
    }
    """

    static let buyCover = """
    mutation BuyCover($venueId: ID!) {
      buyCover(input: { venueId: $venueId }) {
        admission { \(admissionFields) }
        provider paymentIntentClientSecret publishableKey stripeAccountId squareApplicationId squareLocationId
      }
    }
    """

    static let payCover = """
    mutation PayCover($admissionId: ID!, $sourceId: String!, $verificationToken: String) {
      payCover(input: { admissionId: $admissionId, sourceId: $sourceId, verificationToken: $verificationToken }) {
        admission { \(admissionFields) }
      }
    }
    """

    static let confirmCover = """
    mutation ConfirmCover($admissionId: ID!) {
      confirmCover(input: { admissionId: $admissionId }) { admission { \(admissionFields) } }
    }
    """

    static let refundAdmission = """
    mutation RefundAdmission($admissionId: ID!) {
      refundAdmission(input: { admissionId: $admissionId }) { admission { \(admissionFields) } }
    }
    """

    /// Staff work: sent to ``GraphQLEndpoint/staff``.
    static let scanAdmission = """
    # endpoint: staff
    mutation ScanAdmission($venueId: ID!, $code: String!) {
      scanAdmission(input: { venueId: $venueId, code: $code }) {
        result { outcome message admission { \(admissionFields) } }
      }
    }
    """

    static let node = """
    query Node($id: ID!) {
      node(id: $id) { __typename id }
    }
    """
}

/// A connection read as `nodes { … }`: the mixin lists (`venues { list }`, `me { cover { admissions } }`) are connections.
struct Nodes<Element: Decodable & Sendable>: Decodable, Sendable { var nodes: [Element] }

/// `venues { list { nodes } }` on the root, the audience.
struct VenuesResponse: Decodable, Sendable {
    struct Mixin: Decodable, Sendable { var list: Nodes<Venue> }

    private var venues: Mixin?
    var list: [Venue] { venues?.list.nodes ?? [] }
}

/// `people { list { nodes } }` on the root, the audience.
struct PeopleResponse: Decodable, Sendable {
    struct Mixin: Decodable, Sendable { var list: Nodes<Person> }

    private var people: Mixin?
    var list: [Person] { people?.list.nodes ?? [] }
}

/// `locales` on the root, the audience.
struct LocalesResponse: Decodable, Sendable { var locales: [AudienceLocale]? }
/// `me { self }`: the viewer's state (UserState), and their own profile in it (SelfUser).
struct MeResponse: Decodable, Sendable {
    struct State: Decodable, Sendable {
        var profile: SelfUser?

        private enum CodingKeys: String, CodingKey { case profile = "self" }
    }

    var me: State?
}
struct NodeResponse: Decodable, Sendable { var node: Node? }
struct ClosestLocaleResponse: Decodable, Sendable { var closestLocale: AudienceLocale? }
struct RegisterDeviceResponse: Decodable, Sendable {
    struct Payload: Decodable, Sendable { var registered: Bool }
    var registerDevice: Payload
}
struct TribesResponse: Decodable, Sendable {
    struct Profile: Decodable, Sendable { var tribes: [TribeIdentification] }
    struct Mine: Decodable, Sendable {
        var profile: Profile?

        private enum CodingKeys: String, CodingKey { case profile = "self" }
    }
    var tribes: [Tag]?
    var me: Mine?
}
struct TribesPayload: Decodable, Sendable { var tribes: [TribeIdentification] }
struct IdentifyWithTribeResponse: Decodable, Sendable { var identifyWithTribe: TribesPayload }
struct LeaveTribeResponse: Decodable, Sendable { var leaveTribe: TribesPayload }
/// `rsvpEvent { event { rsvp { mine } } }`: the signed-in user's answer, from the event's rsvp mixin.
struct RSVPEventResponse: Decodable, Sendable {
    struct RSVP: Decodable, Sendable { var mine: RSVPState }
    struct Event: Decodable, Sendable { var rsvp: RSVP }
    struct Payload: Decodable, Sendable { var event: Event }
    var rsvpEvent: Payload
}
/// `venues { venue(id:) }`.
struct VenueCoverResponse: Decodable, Sendable {
    struct Venues: Decodable, Sendable { var venue: VenueCover? }

    var venues: Venues
    var venue: VenueCover? { venues.venue }
}

/// `me { cover { admissions { nodes } } }`: the viewer's passes are theirs, under `me`.
struct AdmissionsResponse: Decodable, Sendable {
    struct Cover: Decodable, Sendable { var admissions: Nodes<Admission> }
    struct Me: Decodable, Sendable { var cover: Cover }

    var me: Me?
    var admissions: [Admission] { me?.cover.admissions.nodes ?? [] }
}

/// `me { cover { doorVenues { nodes } } }`.
struct DoorVenuesResponse: Decodable, Sendable {
    struct Cover: Decodable, Sendable { var doorVenues: Nodes<DoorVenue> }
    struct Me: Decodable, Sendable { var cover: Cover }

    var me: Me?
    var doorVenues: [DoorVenue] { me?.cover.doorVenues.nodes ?? [] }
}

/// `venues { venue(id:) }`.
struct VenueDoorResponse: Decodable, Sendable {
    struct Venues: Decodable, Sendable { var venue: DoorVenue? }

    var venues: Venues
    var venue: DoorVenue? { venues.venue }
}
struct BuyCoverResponse: Decodable, Sendable { var buyCover: CoverPurchase }
struct AdmissionPayload: Decodable, Sendable { var admission: Admission }
struct ConfirmCoverResponse: Decodable, Sendable { var confirmCover: AdmissionPayload }
struct PayCoverResponse: Decodable, Sendable { var payCover: AdmissionPayload }
struct RefundAdmissionResponse: Decodable, Sendable { var refundAdmission: AdmissionPayload }
struct ScanAdmissionResponse: Decodable, Sendable {
    struct Payload: Decodable, Sendable { var result: ScanResult }
    var scanAdmission: Payload
}
