// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "hog",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "hog", targets: ["hog"]),
        .executable(name: "HogBar", targets: ["HogBar"]),
        .library(name: "HogCore", targets: ["HogCore"]),
    ],
    targets: [
        .target(
            name: "HogCore",
            resources: [
                .copy("Resources/catalog"),
                .copy("Resources/rules"),
                .copy("Resources/explain"),
            ]
        ),
        .executableTarget(name: "hog", dependencies: ["HogCore"]),
        .executableTarget(name: "HogBar", dependencies: ["HogCore"]),
        .testTarget(
            name: "HogCoreTests",
            dependencies: ["HogCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "hogTests", dependencies: ["hog"]),
    ]
)
