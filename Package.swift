// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ConsentIQ",
    platforms: [.iOS(.v16), .macOS(.v12)],
    products: [
        .library(name: "ConsentIQ", targets: ["ConsentIQ"]),
    ],
    targets: [
        .target(name: "ConsentIQ", path: "Sources/ConsentIQ"),
        .testTarget(name: "ConsentIQTests", dependencies: ["ConsentIQ"], path: "Tests/ConsentIQTests"),
    ]
)
