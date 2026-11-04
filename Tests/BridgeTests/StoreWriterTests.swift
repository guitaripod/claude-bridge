import Foundation
import Testing

@testable import claude_bridge

/// The store on disk is what a restarted bridge comes back to, so the writer that moved off the
/// store's actor and split each conversation into a file of its own still has to read back exactly
/// the store it was given, never an older one than it already wrote, and still read a store written
/// whole before the split.
@Suite struct StoreWriterTests {
    private func session(_ id: String, _ text: String) -> Session {
        let json = #"""
            {"id":"\#(id)","title":"T \#(id)","model":"opus","effort":"high",
             "createdAt":"2026-11-04T10:00:00Z","updatedAt":"2026-11-04T10:05:00Z",
             "messages":[{"id":"m-\#(id)","role":"assistant","createdAt":"2026-11-04T10:01:00Z",
                          "parts":[{"kind":"text","text":"\#(text)"}]}]}
            """#
        return try! JSONCoding.decoder.decode(Session.self, from: Data(json.utf8))
    }

    private func read(_ url: URL) throws -> [Session] {
        try #require(StoreWriter.load(from: url))
    }

    private func conversation(_ id: String, besides url: URL) -> URL {
        StoreWriter.messagesURL(for: id, besides: url)
    }

    private func modified(_ file: URL) throws -> Date {
        try #require(
            FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
    }

    private func scratch() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("store-writer-\(UUID().uuidString)")
            .appendingPathComponent("sessions.json")
    }

    @Test func theFileReadsBackAsTheSnapshotItWasGiven() throws {
        let url = scratch()
        let writer = StoreWriter(url: url)
        let first = [session("a", "one"), session("b", "two")]
        writer.write(first, generation: 1)
        #expect(try read(url) == first)

        let second = [session("a", "one"), session("b", "two, edited"), session("c", "three")]
        writer.write(second, generation: 2)
        #expect(try read(url) == second)

        let fewer = [session("c", "three")]
        writer.write(fewer, generation: 3)
        #expect(try read(url) == fewer)
    }

    @Test func aSnapshotOlderThanTheFileIsNeverWritten() throws {
        let url = scratch()
        let writer = StoreWriter(url: url)
        let newer = [session("a", "newer")]
        writer.write(newer, generation: 5)
        writer.write([session("a", "older")], generation: 4)
        writer.write([session("a", "same generation")], generation: 5)
        #expect(try read(url) == newer)
    }

    @Test func theStoreReadsBackAsAWholeEncodingWouldHaveIt() throws {
        let url = scratch()
        let writer = StoreWriter(url: url)
        let sessions = (0..<5).map { session("s\($0)", "text \($0)") }
        writer.write(sessions, generation: 1)
        writer.write(sessions, generation: 2)
        let whole = try JSONCoding.decoder.decode(
            [Session].self, from: JSONCoding.encoder.encode(sessions))
        #expect(try read(url) == whole)
    }

    @Test func theIndexCarriesNoMessages() throws {
        let url = scratch()
        StoreWriter(url: url).write([session("a", "one"), session("b", "two")], generation: 1)
        let index = try JSONCoding.decoder.decode([Session].self, from: Data(contentsOf: url))
        #expect(index.map(\.id) == ["a", "b"])
        #expect(index.allSatisfy { $0.messages.isEmpty })
        #expect(index.map(\.title) == ["T a", "T b"])
    }

    @Test func anUnchangedConversationIsNotWrittenAgain() throws {
        let url = scratch()
        let writer = StoreWriter(url: url)
        writer.write([session("a", "one"), session("b", "two")], generation: 1)
        let still = conversation("a", besides: url)
        let changed = conversation("b", besides: url)
        let past = Date(timeIntervalSince1970: 1_000_000)
        for file in [still, changed] {
            try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: file.path)
        }
        writer.write([session("a", "one"), session("b", "two, edited")], generation: 2)
        #expect(try modified(still) == past)
        #expect(try modified(changed) != past)
    }

    @Test func aConversationThatLeftTheStoreLeavesNoFile() throws {
        let url = scratch()
        let writer = StoreWriter(url: url)
        writer.write([session("a", "one"), session("b", "two")], generation: 1)
        #expect(FileManager.default.fileExists(atPath: conversation("b", besides: url).path))
        writer.write([session("a", "one")], generation: 2)
        #expect(!FileManager.default.fileExists(atPath: conversation("b", besides: url).path))
        #expect(FileManager.default.fileExists(atPath: conversation("a", besides: url).path))
    }

    @Test func aMissingConversationFileIsWrittenAgain() throws {
        let url = scratch()
        let writer = StoreWriter(url: url)
        let sessions = [session("a", "one")]
        writer.write(sessions, generation: 1)
        try FileManager.default.removeItem(at: conversation("a", besides: url))
        writer.write(sessions, generation: 2)
        #expect(try read(url) == sessions)
    }

    @Test func aStoreWrittenWholeBeforeTheSplitReadsAndSplits() throws {
        let url = scratch()
        let legacy = [session("a", "one"), session("b", "two")]
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONCoding.encoder.encode(legacy).write(to: url)
        let loaded = try read(url)
        #expect(loaded == legacy)

        StoreWriter(url: url).write(loaded, generation: 1)
        let index = try JSONCoding.decoder.decode([Session].self, from: Data(contentsOf: url))
        #expect(index.allSatisfy { $0.messages.isEmpty })
        #expect(try read(url) == legacy)
    }

    @Test func anIdThatIsNotAFileNameStaysInsideTheFolder() {
        let url = scratch()
        let file = StoreWriter.messagesURL(for: "../../etc/passwd", besides: url)
        #expect(file.deletingLastPathComponent().path == StoreWriter.directory(besides: url).path)
        #expect(file.lastPathComponent == "______etc_passwd.json")
    }

    @Test func noStoreReadsAsNothing() {
        #expect(StoreWriter.load(from: scratch()) == nil)
    }
}
