// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "DrillSergeant",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "DrillSergeant", targets: ["DrillSergeant"]),
    ],
    targets: [
        .executableTarget(
            name: "DrillSergeant",
            path: "Sources/DrillSergeant"
        ),
        .testTarget(
            name: "DrillSergeantTests",
            dependencies: ["DrillSergeant"],
            path: "Tests/DrillSergeantTests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
