import Foundation
import Testing

@testable import claude_bridge

@Suite struct ProcessProbeTests {
    @Test("A spawned child is found under its parent, with a CPU reading and a command line")
    func childIsFoundWithReadings() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", "sleep 30"]
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        defer { child.terminate() }
        let me = ProcessInfo.processInfo.processIdentifier
        let children = ProcessProbe.children(of: me)
        #expect(children.contains(child.processIdentifier))
        #expect(ProcessProbe.descendants(of: me).contains(child.processIdentifier))
        #expect(ProcessProbe.cpuSeconds(of: child.processIdentifier) >= 0)
        let line = ProcessProbe.commandLine(child.processIdentifier)
        #expect(line?.contains("sleep 30") == true, "command line read as \(String(describing: line))")
    }

    @Test("ps clock forms read back as seconds")
    func clockParsing() {
        #expect(ProcessProbe.parseClock("0:00.01") == 0.01)
        #expect(ProcessProbe.parseClock("1:02:03") == 3723)
        #expect(ProcessProbe.parseClock("2-01:00:00") == 2 * 86400 + 3600)
        #expect(ProcessProbe.parseClock("") == 0)
    }

    @Test("The needle is the command's first line up to its first quote, or nothing")
    func needleForTask() {
        let task = ClaudeProcess.LiveTask(
            description: "x", kind: "local_bash",
            shell: ClaudeProcess.ShellCall(
                toolUseID: "t", command: "cd ~/Dev && grep -rl 'needle' . | head", budget: 120,
                explicit: false, outputFile: nil))
        #expect(ClaudeProcess.needle(for: task) == "cd ~/Dev && grep -rl")
        let short = ClaudeProcess.LiveTask(description: "ls", kind: "local_bash")
        #expect(ClaudeProcess.needle(for: short) == nil)
        #expect(
            ClaudeProcess.outputFile(
                in: "Command running in background with ID: b1. Output is being written to: /tmp/x/tasks/b1.output. You will be notified.")
                == "/tmp/x/tasks/b1.output")
    }
}
