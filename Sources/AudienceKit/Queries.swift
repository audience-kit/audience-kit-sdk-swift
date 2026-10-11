import AudienceCore
import Foundation

/// The GraphQL documents behind the client's typed helpers. Public so apps can reuse the fragments
/// in their own operations and decode into the same models.
public enum Queries {
    public static let pageFields = "id name photoUrl bannerUrl"
    public static let localeFields = "id name label cityNames bannerUrl profile { places { placeId } }"
    /// A tag on a venue, person or event: its name and chip color.
    public static let tagFields = "id name color"
    /// A person's home venue or gig venue: where it is, and which of the signed-in user's
    /// friends are there now.
    public static let personVenueFields = "id name photoUrl locale { id name } friends { id name facebookId presence }"
    /// One of a person's events (`PersonEvent`), on its own or as the node of a `PersonEventInvolvement`. Its
    /// `venue` is the events facet: a display name ("To be announced" when there is none) and the venue, if any.
    public static let personEventFields = "id name startAt locale { id name } venue { name venue { \(personVenueFields) } } tags { \(tagFields) }"

    public static let audience = """
    query Audience {
      audience { id name subdomain theme { preset tagline light { name value } dark { name value } } }
    }
    """

    public static let venues = """
    query Venues {
      venues {
        id name hidden order photoUrl bannerUrl
        profile { facebook { page { \(pageFields) } } }
        locale { \(localeFields) }
        location { id point googlePlaceId address }
        tags { \(tagFields) }
      }
    }
    """

    public static let people = """
    query People {
      people {
        id name order global likeRequired profile { facebook { page { \(pageFields) } } }
        venues { home { \(personVenueFields) } }
        locales { id name }
        events { involvements { edges { relationship role via { id name } node { \(personEventFields) } } } }
        tags { \(tagFields) }
      }
    }
    """

    public static let locales = """
    query Locales {
      locales { \(localeFields) }
    }
    """

    public static let me = """
    query Me {
      me { id name firstName lastName emailAddress isAdmin presence }
    }
    """

    public static let closestLocale = """
    query ClosestLocale($near: CoordinatesInput!) {
      closestLocale(near: $near) { \(localeFields) }
    }
    """

    /// Records the user's position and says where that is: `venue` when they're in one, else `locale` and
    /// its `nearbyVenues`, plus `audience` for its facets. Select the fields the app needs (with the facets it
    /// reads, such as `venue { friends { list { name } } }`) and decode the result yourself; `$position` is a
    /// ``Coordinates/graphQLValue``.
    public static func reportLocation(selecting fields: String) -> String {
        """
        mutation ReportLocation($position: CoordinatesInput!) {
          reportLocation(input: { position: $position }) { \(fields) }
        }
        """
    }

    public static let rsvpEvent = """
    mutation RSVPEvent($eventId: ID!, $state: RSVPState!) {
      rsvpEvent(input: { eventId: $eventId, state: $state }) { event { id viewerRsvp } }
    }
    """

    /// The tribes people can identify with here, and the signed-in user's own.
    public static let tribes = """
    query Tribes {
      audience { id tribes { \(tagFields) tribe } }
      me { id tribes { isPrivate tag { \(tagFields) tribe } } }
    }
    """

    public static let identifyWithTribe = """
    mutation IdentifyWithTribe($tagId: ID!, $isPrivate: Boolean) {
      identifyWithTribe(input: { tagId: $tagId, isPrivate: $isPrivate }) {
        tribes { isPrivate tag { \(tagFields) tribe } }
      }
    }
    """

    public static let leaveTribe = """
    mutation LeaveTribe($tagId: ID!) {
      leaveTribe(input: { tagId: $tagId }) { tribes { isPrivate tag { \(tagFields) tribe } } }
    }
    """

    public static let registerDevice = """
    mutation RegisterDevice($notificationToken: String!) {
      registerDevice(input: { notificationToken: $notificationToken }) { registered }
    }
    """

    /// A ``CoverCharge``.
    public static let coverChargeFields = "amountCents totalCents feeCents currency night from payable event { id name }"
    /// An ``Admission``, with the pass secret the buyer makes the QR code from.
    public static let admissionFields = """
    id status night amountCents totalCents currency isRefundable passSecret scanCount checkedInAt \
    userName userPhotoUrl venue { id name photoUrl } event { id name }
    """
    public static let doorNightFields = "night paidCount checkedInCount grossCents"

    public static let venueCover = """
    query VenueCover($id: ID!) {
      venue(id: $id) {
        id name
        cover {
          charge { \(coverChargeFields) }
          viewerAdmission { \(admissionFields) }
        }
      }
    }
    """

    public static let admissions = """
    query Admissions {
      admissions { \(admissionFields) }
    }
    """

    public static let doorVenues = """
    query DoorVenues {
      doorVenues { id name photoUrl cover { door { \(doorNightFields) } } }
    }
    """

    public static let venueDoor = """
    query VenueDoor($id: ID!, $night: ISO8601Date) {
      venue(id: $id) { id name photoUrl cover { door(night: $night) { \(doorNightFields) } } }
    }
    """

    public static let buyCover = """
    mutation BuyCover($venueId: ID!) {
      buyCover(input: { venueId: $venueId }) {
        admission { \(admissionFields) }
        provider paymentIntentClientSecret publishableKey stripeAccountId squareApplicationId squareLocationId
      }
    }
    """

    public static let payCover = """
    mutation PayCover($admissionId: ID!, $sourceId: String!, $verificationToken: String) {
      payCover(input: { admissionId: $admissionId, sourceId: $sourceId, verificationToken: $verificationToken }) {
        admission { \(admissionFields) }
      }
    }
    """

    public static let confirmCover = """
    mutation ConfirmCover($admissionId: ID!) {
      confirmCover(input: { admissionId: $admissionId }) { admission { \(admissionFields) } }
    }
    """

    public static let refundAdmission = """
    mutation RefundAdmission($admissionId: ID!) {
      refundAdmission(input: { admissionId: $admissionId }) { admission { \(admissionFields) } }
    }
    """

    public static let scanAdmission = """
    mutation ScanAdmission($venueId: ID!, $code: String!) {
      scanAdmission(input: { venueId: $venueId, code: $code }) {
        result { outcome message admission { \(admissionFields) } }
      }
    }
    """

    public static let node = """
    query Node($id: ID!) {
      node(id: $id) { __typename id }
    }
    """
}

struct AudienceResponse: Decodable, Sendable { var audience: Audience? }
struct VenuesResponse: Decodable, Sendable { var venues: [Venue] }
struct PeopleResponse: Decodable, Sendable { var people: [Person] }
struct LocalesResponse: Decodable, Sendable { var locales: [AudienceLocale] }
struct MeResponse: Decodable, Sendable { var me: User? }
struct NodeResponse: Decodable, Sendable { var node: Node? }
struct ClosestLocaleResponse: Decodable, Sendable { var closestLocale: AudienceLocale? }
struct RegisterDeviceResponse: Decodable, Sendable {
    struct Payload: Decodable, Sendable { var registered: Bool }
    var registerDevice: Payload
}
struct TribesResponse: Decodable, Sendable {
    struct Available: Decodable, Sendable { var tribes: [Tag] }
    struct Mine: Decodable, Sendable { var tribes: [TribeIdentification] }
    var audience: Available?
    var me: Mine?
}
struct TribesPayload: Decodable, Sendable { var tribes: [TribeIdentification] }
struct IdentifyWithTribeResponse: Decodable, Sendable { var identifyWithTribe: TribesPayload }
struct LeaveTribeResponse: Decodable, Sendable { var leaveTribe: TribesPayload }
struct RSVPEventResponse: Decodable, Sendable {
    struct Event: Decodable, Sendable { var viewerRsvp: RSVPState }
    struct Payload: Decodable, Sendable { var event: Event }
    var rsvpEvent: Payload
}
struct VenueCoverResponse: Decodable, Sendable { var venue: VenueCover? }
struct AdmissionsResponse: Decodable, Sendable { var admissions: [Admission] }
struct DoorVenuesResponse: Decodable, Sendable { var doorVenues: [DoorVenue] }
struct VenueDoorResponse: Decodable, Sendable { var venue: DoorVenue? }
struct BuyCoverResponse: Decodable, Sendable { var buyCover: CoverPurchase }
struct AdmissionPayload: Decodable, Sendable { var admission: Admission }
struct ConfirmCoverResponse: Decodable, Sendable { var confirmCover: AdmissionPayload }
struct PayCoverResponse: Decodable, Sendable { var payCover: AdmissionPayload }
struct RefundAdmissionResponse: Decodable, Sendable { var refundAdmission: AdmissionPayload }
struct ScanAdmissionResponse: Decodable, Sendable {
    struct Payload: Decodable, Sendable { var result: ScanResult }
    var scanAdmission: Payload
}
