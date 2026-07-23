// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ai-brain",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "BrainKit", targets: ["BrainKit"]),
        .executable(name: "brain", targets: ["brain"]),
        // Named BrainApp (not Brain): macOS filesystems are case-insensitive, so a
        // product "Brain" would clobber the "brain" CLI in .build/release/.
        .executable(name: "BrainApp", targets: ["BrainApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.9.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
    ],
    targets: [
        .target(
            name: "BrainKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Yams", package: "Yams"),
            ]
        ),
        .executableTarget(
            name: "brain",
            dependencies: [
                "BrainKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
        .executableTarget(name: "BrainApp", dependencies: ["BrainKit"]),
        .testTarget(name: "BrainKitTests", dependencies: ["BrainKit"]),
        .testTarget(name: "BrainAppTests", dependencies: ["BrainApp"]),
    ]
)
