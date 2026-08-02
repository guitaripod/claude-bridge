import Foundation
import Testing

@testable import claude_bridge

/// The catalog's promise: everything a typed `/name` would actually resolve on this machine —
/// command files, skills, saved workflows — is listed exactly once, under the name that runs it.
@Suite struct CommandCatalogTests {
    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("catalog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func write(_ path: String, _ contents: String, in root: URL) throws {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: file, atomically: true, encoding: .utf8)
    }

    private func catalog(home: URL, directory: String? = nil) -> [AgentCommand] {
        CommandCatalog.all(home: home.path, directory: directory)
    }

    @Test func userSkillListsUnderItsDirectoryName() throws {
        let home = try makeHome()
        try write(
            ".claude/skills/steam-add-game/SKILL.md",
            "---\ndescription: Install a game into Steam\nargument-hint: <path>\n---\nBody",
            in: home)
        let skill = try #require(catalog(home: home).first { $0.name == "steam-add-game" })
        #expect(skill.source == "skill")
        #expect(skill.description == "Install a game into Steam")
        #expect(skill.argumentHint == "<path>")
        #expect(skill.scope == nil)
    }

    @Test func skillMarkedNotUserInvocableIsHidden() throws {
        let home = try makeHome()
        try write(
            ".claude/skills/internal/SKILL.md",
            "---\ndescription: Model-only helper\nuser-invocable: false\n---\nBody",
            in: home)
        #expect(!catalog(home: home).contains { $0.name == "internal" })
    }

    @Test func commandFileWinsOverSkillOfTheSameName() throws {
        let home = try makeHome()
        try write(".claude/commands/deploy.md", "---\ndescription: Command file\n---\nGo", in: home)
        try write(
            ".claude/skills/deploy/SKILL.md", "---\ndescription: Skill twin\n---\nBody", in: home)
        let matches = catalog(home: home).filter { $0.name == "deploy" }
        #expect(matches.count == 1)
        #expect(matches.first?.source == "user")
    }

    @Test func projectSkillCarriesTheProjectScope() throws {
        let home = try makeHome()
        let project = home.appendingPathComponent("Dev/rocket")
        try write("Dev/rocket/.claude/skills/launch/SKILL.md", "---\ndescription: Lift off\n---\nBody", in: home)
        let skill = try #require(
            catalog(home: home, directory: project.path).first { $0.name == "launch" })
        #expect(skill.source == "skill")
        #expect(skill.scope == "rocket")
    }

    @Test func pluginSkillIsNamespacedLikePluginCommands() throws {
        let home = try makeHome()
        let install = home.appendingPathComponent("plugin-install")
        try write("plugin-install/skills/perf/SKILL.md", "---\ndescription: Audit speed\n---\nBody", in: home)
        try write(
            ".claude/plugins/installed_plugins.json",
            #"{"plugins": {"cloudflare@official": [{"installPath": "\#(install.path)"}]}}"#,
            in: home)
        let skill = try #require(catalog(home: home).first { $0.name == "cloudflare:perf" })
        #expect(skill.source == "skill")
        #expect(skill.scope == "cloudflare")
    }

    @Test func strayFileInTheSkillsRootIsIgnored() throws {
        let home = try makeHome()
        try write(".claude/skills/README.md", "not a skill", in: home)
        #expect(!catalog(home: home).contains { $0.name == "README" })
    }

    @Test func workflowReadsItsMetaLiteral() throws {
        let home = try makeHome()
        try write(
            ".claude/workflows/flyr.js",
            """
            export const meta = {
              name: 'flyr',
              description: "Fan out flight searches",
              phases: [{ title: 'Search' }],
            }
            return {}
            """,
            in: home)
        let workflow = try #require(catalog(home: home).first { $0.name == "flyr" })
        #expect(workflow.source == "skill")
        #expect(workflow.scope == "workflow")
        #expect(workflow.description == "Fan out flight searches")
    }

    @Test func workflowWithoutMetaFallsBackToItsFilename() throws {
        let home = try makeHome()
        try write(".claude/workflows/mystery.js", "return {}", in: home)
        let workflow = try #require(catalog(home: home).first { $0.name == "mystery" })
        #expect(workflow.description == "Saved workflow")
    }

    @Test func symlinkedSkillsAndWorkflowsRootsStillList() throws {
        let home = try makeHome()
        try write("dotfiles/skills/linked/SKILL.md", "---\ndescription: Via symlink\n---\nBody", in: home)
        try write("dotfiles/workflows/linked-wf.js", "export const meta = { name: 'linked-wf', description: 'Via symlink' }", in: home)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent(".claude/skills"),
            withDestinationURL: home.appendingPathComponent("dotfiles/skills"))
        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent(".claude/workflows"),
            withDestinationURL: home.appendingPathComponent("dotfiles/workflows"))
        let names = catalog(home: home).map(\.name)
        #expect(names.contains("linked"))
        #expect(names.contains("linked-wf"))
    }

    @Test func builtinsSurviveAnEmptyMachine() throws {
        let home = try makeHome()
        let names = catalog(home: home).map(\.name)
        #expect(names.contains("compact"))
        #expect(names.contains("usage"))
    }
}
