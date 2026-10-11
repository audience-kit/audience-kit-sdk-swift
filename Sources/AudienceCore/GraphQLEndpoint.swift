import Foundation

/// Which of an audience's GraphQL endpoints a request goes to. They serve the same graph: the consumer view grants a
/// signed-in member their own records and nothing more, whatever their role, and leaves out what no member could
/// use; the staff view (staffql) is for staff tools (an admin console, venue and talent apps, venue devices), whose
/// roles grant what they grant there, and turns anyone else away.
public enum GraphQLEndpoint: String, Sendable, CaseIterable {
    /// `/v1/audience/<id>/graphql`, for the apps people use.
    case consumer = "graphql"
    /// `/v1/audience/<id>/staffql`, for staff tools.
    case staff = "staffql"

    /// The endpoint's path for an audience.
    public func path(audienceID: String) -> String {
        "/v1/audience/\(audienceID)/\(rawValue)"
    }
}
