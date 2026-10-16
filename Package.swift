// swift-tools-version:6.0
import Foundation
import PackageDescription

let package = Package(
    name: "claude-bridge",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        Kit.dependency,
    ],
    targets: [
        .executableTarget(
            name: "claude-bridge",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "PairingKit", package: "CodingAgentKit"),
            ]
        ),
        .testTarget(
            name: "BridgeTests",
            dependencies: ["claude-bridge"]
        ),
    ]
)

/// Where CodingAgentKit is read from. A working copy beside this one wins, so a change that spans
/// both lands in one edit; every other tree, a packager's clone or a CI runner's, resolves the
/// published tag. `CLAUDE_BRIDGE_KIT_REMOTE=1` skips straight to the tag, which a release build
/// sets so it can never be made from an unpublished working copy.
enum Kit {
    static let remote = "https://github.com/guitaripod/CodingAgentKit.git"
    static let version = Version(0, 38, 0)

    static var dependency: Package.Dependency {
        let forced = ProcessInfo.processInfo.environment["CLAUDE_BRIDGE_KIT_REMOTE"] ?? ""
        guard forced.isEmpty || forced == "0" else {
            return .package(url: remote, from: version)
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sibling = "../CodingAgentKit"
        let path = root.appendingPathComponent(sibling).standardizedFileURL.path
        if FileManager.default.fileExists(atPath: path + "/Package.swift") {
            return .package(path: sibling)
        }
        return .package(url: remote, from: version)
    }
}
