import Testing
@testable import AudienceKit

@Test func versionIsSet() {
    #expect(!AudienceKit.version.isEmpty)
}
