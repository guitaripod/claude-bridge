import Foundation
import Testing

@testable import claude_bridge

/// The prebuilt binary a release ships answers `--version` from a constant, and the release script
/// packages it under the newest numbered heading in the CHANGELOG, below any Unreleased section.
/// Two numbers that must be one are pinned together here.
@Suite struct VersionTests {
    @Test func theCompiledVersionIsTheChangelogHead() throws {
        let changelog = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("CHANGELOG.md")
        let text = try String(contentsOf: changelog, encoding: .utf8)
        let head = text.split(separator: "\n")
            .compactMap { line -> String? in
                guard line.hasPrefix("## ") else { return nil }
                let word = line.dropFirst(3).split(separator: " ").first.map(String.init)
                return word.flatMap { $0.first?.isNumber == true ? $0 : nil }
            }
            .first
        #expect(head == BridgeVersion.fallback)
    }

    @Test func versionIsAskedForByFlagOrWord() {
        #expect(BridgeVersion.isVersionRequest(["claude-bridge", "--version"]))
        #expect(BridgeVersion.isVersionRequest(["claude-bridge", "version"]))
    }

    @Test func nothingElseIsAVersionRequest() {
        #expect(!BridgeVersion.isVersionRequest(["claude-bridge"]))
        #expect(!BridgeVersion.isVersionRequest(["claude-bridge", "pair"]))
        #expect(!BridgeVersion.isVersionRequest(["--version"]))
    }

    @Test func theLineNamesTheBridgeAndItsVersion() {
        #expect(BridgeVersion.versionLine() == "claude-bridge \(BridgeVersion.fallback)")
    }

    @Test func anArgumentTheBridgeDoesNotKnowIsRefusedRatherThanIgnored() {
        #expect(BridgeVersion.unknownCommand(["claude-bridge", "pair"]) == "pair")
        #expect(BridgeVersion.unknownCommand(["claude-bridge", "--port", "1"]) == "--port")
        #expect(BridgeVersion.unknownCommand(["claude-bridge"]) == nil)
        #expect(BridgeVersion.unknownCommand(["claude-bridge", "--version"]) == nil)
    }
}
