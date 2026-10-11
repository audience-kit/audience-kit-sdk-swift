import AudienceCore
import Foundation
import AudienceCore

extension AudienceSession {
    /// The audience, with its theme.
    public func audience() async throws -> Audience {
        let response = try await graphQL(Queries.audience, operationName: "Audience", as: AudienceResponse.self)
        guard let audience = response.audience else { throw AudienceKitError.notFound }
        return audience
    }

    /// The audience's venues.
    public func venues() async throws -> [Venue] {
        try await graphQL(Queries.venues, operationName: "Venues", as: VenuesResponse.self).venues
    }

    /// The people the audience follows.
    public func people() async throws -> [Person] {
        try await graphQL(Queries.people, operationName: "People", as: PeopleResponse.self).people
    }

    /// The audience's locales.
    public func locales() async throws -> [AudienceLocale] {
        try await graphQL(Queries.locales, operationName: "Locales", as: LocalesResponse.self).locales
    }

    /// The signed-in user, or `nil` when the API has no current user.
    public func me() async throws -> User? {
        try await graphQL(Queries.me, operationName: "Me", as: MeResponse.self).me
    }

    /// Any object by its global ID, or `nil` when it doesn't exist or belongs to another audience.
    public func node(id: String) async throws -> Node? {
        try await graphQL(Queries.node, variables: ["id": .string(id)], operationName: "Node",
                          as: NodeResponse.self).node
    }

    /// The audience's locale nearest a position, or `nil` when it has none.
    public func closestLocale(near position: Coordinates) async throws -> AudienceLocale? {
        try await graphQL(Queries.closestLocale, variables: ["near": position.graphQLValue],
                          operationName: "ClosestLocale", as: ClosestLocaleResponse.self).closestLocale
    }

    /// Sets the signed-in user's RSVP to an event in AudienceKit (it isn't sent to Facebook).
    @discardableResult
    public func setRSVP(_ state: RSVPState, forEvent eventID: String) async throws -> RSVPState {
        try await graphQL(Queries.rsvpEvent, variables: ["eventId": .string(eventID), "state": .string(state.rawValue)],
                          operationName: "RSVPEvent", as: RSVPEventResponse.self).rsvpEvent.event.viewerRsvp
    }

    /// The tribes people can identify with here, and the signed-in user's own (empty when signed out).
    public func tribes() async throws -> Tribes {
        let data = try await graphQL(Queries.tribes, operationName: "Tribes", as: TribesResponse.self)
        return Tribes(available: data.audience?.tribes ?? [], mine: data.me?.tribes ?? [])
    }

    /// Identifies the signed-in user with a tribe, privately unless `isPrivate` is false, or changes that. Returns
    /// their tribes here afterwards.
    @discardableResult
    public func identifyWithTribe(_ tagID: String, isPrivate: Bool = true) async throws -> [TribeIdentification] {
        let variables: [String: GraphQLValue] = ["tagId": .string(tagID), "isPrivate": .bool(isPrivate)]
        return try await graphQL(Queries.identifyWithTribe, variables: variables, operationName: "IdentifyWithTribe",
                                 as: IdentifyWithTribeResponse.self).identifyWithTribe.tribes
    }

    /// Takes the signed-in user out of a tribe; nothing is kept. Returns their tribes here afterwards.
    @discardableResult
    public func leaveTribe(_ tagID: String) async throws -> [TribeIdentification] {
        try await graphQL(Queries.leaveTribe, variables: ["tagId": .string(tagID)], operationName: "LeaveTribe",
                          as: LeaveTribeResponse.self).leaveTribe.tribes
    }

    /// Stores the push notification token for the device this session signed in on.
    public func registerDevice(notificationToken: String) async throws {
        _ = try await graphQL(Queries.registerDevice, variables: ["notificationToken": .string(notificationToken)],
                              operationName: "RegisterDevice", as: RegisterDeviceResponse.self)
    }

    // MARK: - Cover

    /// A venue's cover tonight and the signed-in user's pass for it, or `nil` when the venue doesn't exist.
    public func venueCover(venueID: String) async throws -> VenueCover? {
        try await graphQL(Queries.venueCover, variables: ["id": .string(venueID)], operationName: "VenueCover",
                          as: VenueCoverResponse.self).venue
    }

    /// The signed-in user's cover passes, newest first.
    public func admissions() async throws -> [Admission] {
        try await graphQL(Queries.admissions, operationName: "Admissions", as: AdmissionsResponse.self).admissions
    }

    /// The venues whose door the signed-in user can work, with tonight's counts. Empty for most people.
    public func doorVenues() async throws -> [DoorVenue] {
        try await graphQL(Queries.doorVenues, operationName: "DoorVenues", as: DoorVenuesResponse.self).doorVenues
    }

    /// A venue's door for a night (`yyyy-MM-dd`, tonight by default). `door` is `nil` unless the signed-in user
    /// can work it.
    public func door(venueID: String, night: String? = nil) async throws -> DoorVenue? {
        var variables: [String: GraphQLValue] = ["id": .string(venueID)]
        if let night { variables["night"] = .string(night) }
        return try await graphQL(Queries.venueDoor, variables: variables, operationName: "VenueDoor",
                                 as: VenueDoorResponse.self).venue
    }

    /// Starts paying tonight's cover at a venue. For a Stripe venue, present Stripe's payment sheet with the
    /// result's client secret, publishable key and connected account (`STPAPIClient.shared.stripeAccount`), then
    /// call ``confirmCover(admissionID:)``. For a Square venue (``CoverPurchase/isSquare``), make a payment token
    /// with Square's In-App Payments SDK and call ``payCover(admissionID:sourceID:verificationToken:)``. Asking
    /// again the same night returns the same pass.
    public func buyCover(venueID: String) async throws -> CoverPurchase {
        try await graphQL(Queries.buyCover, variables: ["venueId": .string(venueID)], operationName: "BuyCover",
                          as: BuyCoverResponse.self).buyCover
    }

    /// Pays a Square venue's cover with a payment token (nonce) from Square's In-App Payments SDK: a card, Apple
    /// Pay or Google Pay. The returned pass is paid when Square took the payment.
    public func payCover(admissionID: String, sourceID: String, verificationToken: String? = nil) async throws
        -> Admission {
        var variables: [String: GraphQLValue] = ["admissionId": .string(admissionID), "sourceId": .string(sourceID)]
        if let verificationToken { variables["verificationToken"] = .string(verificationToken) }
        return try await graphQL(Queries.payCover, variables: variables, operationName: "PayCover",
                                 as: PayCoverResponse.self).payCover.admission
    }

    /// Checks a cover payment with its provider after the app finishes paying, so the pass works before the
    /// webhook arrives.
    public func confirmCover(admissionID: String) async throws -> Admission {
        try await graphQL(Queries.confirmCover, variables: ["admissionId": .string(admissionID)],
                          operationName: "ConfirmCover", as: ConfirmCoverResponse.self).confirmCover.admission
    }

    /// Refunds a cover. Buyers can refund their own while ``Admission/isRefundable``.
    public func refundAdmission(admissionID: String) async throws -> Admission {
        try await graphQL(Queries.refundAdmission, variables: ["admissionId": .string(admissionID)],
                          operationName: "RefundAdmission", as: RefundAdmissionResponse.self).refundAdmission.admission
    }

    /// Checks a pass's QR code at a venue's door. The first scan of a paid pass checks them in; later ones that
    /// night are re-entry.
    public func scanAdmission(venueID: String, code: String) async throws -> ScanResult {
        try await graphQL(Queries.scanAdmission, variables: ["venueId": .string(venueID), "code": .string(code)],
                          operationName: "ScanAdmission", as: ScanAdmissionResponse.self).scanAdmission.result
    }

}
