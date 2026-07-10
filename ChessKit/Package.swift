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
        .testTarget(name: "ChessKitTests", dependencies: ["ChessKit"]),
        .testTarget(name: "ChessProtocolTests", dependencies: ["ChessProtocol", "ChessKit"]),
        .testTarget(name: "ChessOnlineTests", dependencies: ["ChessOnline"]),
    ]
)
