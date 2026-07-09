// swift-tools-version:5.5
import PackageDescription

let package = Package(
    name: "chess",
    dependencies: [],
    targets: [
        .executableTarget(
            name: "chess",
            dependencies: []
        ),
        .testTarget(
            name: "chessTests",
            dependencies: ["chess"]
        ),
    ]
)
