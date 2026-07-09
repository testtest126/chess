// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ChessKit",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [
        .library(name: "ChessKit", targets: ["ChessKit"]),
        .library(name: "ChessProtocol", targets: ["ChessProtocol"]),
    ],
    targets: [
        .target(name: "ChessKit"),
        .target(name: "ChessProtocol", dependencies: ["ChessKit"]),
        .testTarget(name: "ChessKitTests", dependencies: ["ChessKit"]),
        .testTarget(name: "ChessProtocolTests", dependencies: ["ChessProtocol", "ChessKit"]),
    ]
)
