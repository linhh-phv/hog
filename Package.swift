// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "hog",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "hog", targets: ["hog"]),
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
        .testTarget(
            name: "HogCoreTests",
            dependencies: ["HogCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
