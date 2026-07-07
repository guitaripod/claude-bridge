// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "claude-bridge",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0")
    ],
    targets: [
        .executableTarget(
            name: "claude-bridge",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird")
            ]
        )
    ]
)
