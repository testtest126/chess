// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ChessKit",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [
        .library(name: "ChessKit", targets: ["ChessKit"]),
        .library(name: "ChessProtocol", targets: ["ChessProtocol"]),
        .library(name: "ChessOnline", targets: ["ChessOnline"]),
    ],
    targets: [
        .target(name: "ChessKit"),
        .target(name: "ChessProtocol", dependencies: ["ChessKit"]),
        .target(name: "ChessOnline"),
        // Engine measurement harness (bench + self-play). Deliberately NOT a
        // library `product`, so it is never linked into the iOS app; it only
        // *calls* the engine, preserving its determinism guarantee. Covered by
        // `swift test` via EngineLabTests, and driven ad hoc by the `engine-lab`
        // executable.
        .target(
            name: "EngineLab",
            dependencies: ["ChessProtocol", "ChessKit"],
            exclude: ["README.md"]
        ),
        .executableTarget(name: "engine-lab", dependencies: ["EngineLab"]),
        .testTarget(name: "ChessKitTests", dependencies: ["ChessKit"]),
        .testTarget(name: "ChessProtocolTests", dependencies: ["ChessProtocol", "ChessKit"]),
        .testTarget(name: "ChessOnlineTests", dependencies: ["ChessOnline"]),
        .testTarget(name: "EngineLabTests", dependencies: ["EngineLab", "ChessProtocol", "ChessKit"]),
    ]
)
