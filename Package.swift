// swift-tools-version: 6.0
// The member-facing AudienceKit Swift SDK: what an audience's own app (Hot Mess)
// builds on. The staff-side management modules are not part of this package.
import PackageDescription

let package = Package(
    name: "AudienceKit",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "AudienceCore", targets: ["AudienceCore"]),
        .library(name: "AudienceKit", targets: ["AudienceKit"]),
        .library(name: "AudienceKitUI", targets: ["AudienceKitUI"]),
    ],
    targets: [
        .target(name: "AudienceCore"),
        .target(name: "AudienceKit", dependencies: ["AudienceCore"]),
        .target(name: "AudienceKitUI", dependencies: ["AudienceCore", "AudienceKit"]),
        .testTarget(name: "AudienceKitTests", dependencies: ["AudienceKit", "AudienceCore", "AudienceKitUI"]),
    ]
)
