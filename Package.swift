// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AudienceKit",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "AudienceKit", targets: ["AudienceKit"]),
    ],
    targets: [
        .target(name: "AudienceKit"),
        .testTarget(name: "AudienceKitTests", dependencies: ["AudienceKit"]),
    ]
)
