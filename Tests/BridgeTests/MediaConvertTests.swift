import Foundation
import Testing

@testable import claude_bridge

/// A WebM or an Ogg asked for by an Apple player is converted once into a copy it can read, and a
/// conversation's note is written for the app that started it.
@Suite("Media conversion and the note an app gets", .serialized)
struct MediaConvertTests {
    @Test("Apple players read MP4, QuickTime and the usual audio as they are")
    func knowsWhatApplePlays() {
        #expect(MediaConvert.playsOnApple("/a/clip.MP4"))
        #expect(MediaConvert.playsOnApple("/a/song.m4a"))
        #expect(!MediaConvert.playsOnApple("/a/run.webm"))
        #expect(!MediaConvert.playsOnApple("/a/cut.mkv"))
        #expect(!MediaConvert.playsOnApple("/a/voice.ogg"))
    }

    @Test("a video becomes H.264 and AAC with its index first, a song AAC")
    func convertsToWhatApplePlays() {
        let video = MediaConvert.arguments(source: "/in.webm", target: "/out.mp4", audio: false)
        #expect(video.contains("libx264") && video.contains("+faststart") && video.contains("0:a:0?"))
        let audio = MediaConvert.arguments(source: "/in.ogg", target: "/out.m4a", audio: true)
        #expect(audio.contains("-vn") && audio.contains("aac") && !audio.contains("libx264"))
    }

    @Test("a WebM is converted once and the copy is played from then on")
    func convertsAWebMOnce() async throws {
        guard let ffmpeg = MediaConvert.ffmpeg() else { return }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("convert-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("run.webm").path
        let made = Shell.runCapturingErrors(
            ffmpeg,
            ["-nostdin", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=10",
             "-t", "1", "-c:v", "libvpx-vp9", source], timeout: 120)
        try #require(made.isEmpty, "\(made)")
        let size = try #require(FileBrowsing.readableSize(source, cap: Int.max))
        let copy = try await MediaConvert.shared.playableCopy(of: source, size: size)
        #expect(copy.hasSuffix(".mp4"))
        #expect(FileManager.default.fileExists(atPath: copy))
        let again = try await MediaConvert.shared.playableCopy(of: source, size: size)
        #expect(again == copy)
        try? FileManager.default.removeItem(atPath: copy)
    }

    @Test("an app that shows named files gets the note that says so, an older one the old note")
    func noteFollowsTheApp() {
        let launch = ClaudeLaunch(
            resume: nil, fork: false, directory: "/tmp/work", ultracode: false, mediaByPath: true)
        let arguments = ClaudeProcess.arguments(
            launch: launch, model: "sonnet", effort: "medium", permissionMode: "bypassPermissions",
            clientNote: true)
        let flag = arguments.firstIndex(of: "--append-system-prompt")
        #expect(flag.map { arguments[$0 + 1] } == ClientNote.mediaText)
        #expect(ClientNote.mediaText.contains("write its absolute path"))
        #expect(!ClientNote.mediaText.contains("\n"))
        #expect(ClientNote.mediaText.count < 800)
        #expect(ClientNote.arguments(enabled: true).last == ClientNote.text)
    }

    @Test("a session keeps what the app that began it can show")
    func sessionKeepsTheFirstApp() {
        var session = Session(
            id: "s", title: "t", directory: nil, claudeSessionID: nil, model: "m", effort: "e",
            createdAt: Date(), updatedAt: Date(), messages: [], lastCostUSD: nil, lastTokens: nil,
            pendingFork: nil)
        #expect(!SessionStore.showsMediaByPath(session))
        session.clientFeatures = ["media-by-path"]
        #expect(SessionStore.showsMediaByPath(session))
    }
}
