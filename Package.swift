// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ai-brain",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "BrainKit", targets: ["BrainKit"]),
        .executable(name: "brain", targets: ["brain"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "BrainKit",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .executableTarget(
            name: "brain",
            dependencies: [
                "BrainKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "BrainKitTests", dependencies: ["BrainKit"]),
    ]
)
