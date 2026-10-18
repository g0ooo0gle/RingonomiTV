// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RingonomiCore",
    platforms: [.macOS(.v13), .tvOS(.v17)],
    products: [
        .library(name: "RingonomiCore", targets: ["RingonomiCore"])
    ],
    targets: [
        .target(name: "RingonomiCore"),
        .executableTarget(name: "RingonomiContractCheck", dependencies: ["RingonomiCore"]),
        .testTarget(name: "RingonomiCoreTests", dependencies: ["RingonomiCore"])
    ]
)
