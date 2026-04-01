// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "VideoTagger",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TaggingKit", targets: ["TaggingKit"]),
        .executable(name: "video-tagger", targets: ["VideoTagger"]),
        .executable(name: "VideoOrganizerApp", targets: ["VideoOrganizer"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/stephencelis/SQLite.swift.git", from: "0.15.3")
    ],
    targets: [
        .target(
            name: "TaggingKit",
            dependencies: [
                .product(name: "SQLite", package: "SQLite.swift")
            ]
        ),
        .executableTarget(
            name: "VideoTagger",
            dependencies: [
                "TaggingKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .executableTarget(
            name: "VideoOrganizer",
            dependencies: ["TaggingKit"],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "TaggingKitTests",
            dependencies: ["TaggingKit"]
        )
    ]
)
