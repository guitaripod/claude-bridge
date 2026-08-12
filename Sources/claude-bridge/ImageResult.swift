import Foundation

/// Recognizes a tool result that handed the model a picture, and turns it into
/// something a client can fetch.
///
/// Claude reads images natively, so a screenshot the agent takes, a chart it
/// renders, or a mockup sitting in the repo all arrive the same way: a
/// `tool_result` whose content is an image block. The transcript records the
/// same event as `toolUseResult.type == "image"` with the media type on the
/// file it kept.
enum ImageResult {
    static func mime(block: [String: Any], result: Any?) -> String? {
        if let result = result as? [String: Any], result["type"] as? String == "image",
            let file = result["file"] as? [String: Any],
            let mime = file["type"] as? String, mime.hasPrefix("image/")
        {
            return mime
        }
        guard let inner = block["content"] as? [[String: Any]] else { return nil }
        for item in inner where item["type"] as? String == "image" {
            let source = item["source"] as? [String: Any]
            let mime = source?["media_type"] as? String
            return (mime?.hasPrefix("image/") == true) ? mime : "image/png"
        }
        return nil
    }

    /// The absolute path the tool was pointed at. A result with no path behind
    /// it stays text: the bridge can only serve bytes it can find again.
    static func path(toolInput: String) -> String? {
        guard let data = toolInput.data(using: .utf8),
            let input = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        for key in ["file_path", "notebook_path", "filePath", "path"] {
            if let value = input[key] as? String, value.hasPrefix("/") { return value }
        }
        return nil
    }

    /// Carries the tool call's id as well as the path, so a file written twice
    /// in one conversation — a screenshot retaken after a fix — is a different
    /// URL each time, and a client caching by URL shows the new picture instead
    /// of the one it already has. The session comes along so the picture
    /// survives the file: a scratch screenshot in `/tmp` is routinely deleted
    /// minutes after the turn that looked at it, and only the transcript still
    /// holds what the model was shown.
    static func url(path: String, toolID: String, session: String?) -> String? {
        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: unreserved),
            let tool = toolID.addingPercentEncoding(withAllowedCharacters: unreserved)
        else { return nil }
        var url = "/files/raw?path=\(encoded)&tool=\(tool)"
        if let session, let id = session.addingPercentEncoding(withAllowedCharacters: unreserved) {
            url += "&session=\(id)"
        }
        return url
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}

/// The copy of a picture the CLI keeps inside the transcript, for when the file
/// the tool read is gone.
///
/// Claude Code records the image it sent the model as base64 on the tool result
/// (`toolUseResult.file.base64`), so a conversation stays legible long after the
/// agent has cleaned up its scratch files. Scanning is line-at-a-time with a
/// substring test before any parsing: transcripts run to tens of megabytes and
/// the record wanted is one line in a hundred thousand.
enum TranscriptImage {
    static func bytes(transcriptPath: String, toolID: String) -> (data: Data, mime: String)? {
        guard let handle = FileHandle(forReadingAtPath: transcriptPath) else { return nil }
        defer { try? handle.close() }
        let needle = Data(toolID.utf8)
        var buffer = Data()
        while let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty {
            buffer.append(chunk)
            var cursor = buffer.startIndex
            while let newline = buffer[cursor...].firstIndex(of: 0x0A) {
                if let found = image(in: buffer[cursor..<newline], needle: needle, toolID: toolID) {
                    return found
                }
                cursor = buffer.index(after: newline)
            }
            buffer = cursor > buffer.startIndex ? Data(buffer[cursor...]) : buffer
        }
        return image(in: buffer[...], needle: needle, toolID: toolID)
    }

    /// Where every picture in a transcript lives, by the id of the tool call that read it.
    ///
    /// A gallery asks for one picture per tap, and a transcript is scanned front to back to find
    /// one line: opening ten pictures scanned the same file ten times. One pass records them all,
    /// by byte scan — no line is parsed as JSON — so the second picture onwards is a seek.
    static func index(transcriptPath: String) -> [String: UInt64] {
        guard let handle = FileHandle(forReadingAtPath: transcriptPath) else { return [:] }
        defer { try? handle.close() }
        var offsets: [String: UInt64] = [:]
        var lineStart: UInt64 = 0
        var buffer = Data()
        func harvest(_ line: Data.SubSequence, at offset: UInt64) {
            guard !line.isEmpty,
                line.range(of: base64Marker) != nil || line.range(of: inlineMarker) != nil
            else { return }
            for id in TranscriptParser.toolUseIDs(in: Data(line)) where offsets[id] == nil {
                offsets[id] = offset
            }
        }
        while let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty {
            buffer.append(chunk)
            var cursor = buffer.startIndex
            while let newline = buffer[cursor...].firstIndex(of: 0x0A) {
                harvest(buffer[cursor..<newline], at: lineStart)
                lineStart += UInt64(buffer.distance(from: cursor, to: newline)) + 1
                cursor = buffer.index(after: newline)
            }
            buffer = cursor > buffer.startIndex ? Data(buffer[cursor...]) : buffer
        }
        harvest(buffer[...], at: lineStart)
        return offsets
    }

    /// One line, read where the index said it was. A file that changed under the offset simply
    /// fails to parse and answers nothing, which sends the caller back to a full scan.
    static func bytes(transcriptPath: String, toolID: String, at offset: UInt64) -> (
        data: Data, mime: String
    )? {
        guard let handle = FileHandle(forReadingAtPath: transcriptPath) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil else { return nil }
        var line = Data()
        while line.count < maxLine {
            guard let chunk = try? handle.read(upToCount: lineChunk), !chunk.isEmpty else { break }
            if let newline = chunk.firstIndex(of: 0x0A) {
                line.append(chunk[chunk.startIndex..<newline])
                break
            }
            line.append(chunk)
        }
        return image(in: line[...], needle: Data(toolID.utf8), toolID: toolID)
    }

    private static let chunkSize = 4 * 1024 * 1024
    private static let lineChunk = 256 * 1024
    private static let maxLine = 64 * 1024 * 1024
    private static let base64Marker = Data("\"base64\"".utf8)
    private static let inlineMarker = Data("\"type\":\"image\"".utf8)

    private static func image(in line: Data.SubSequence, needle: Data, toolID: String) -> (
        data: Data, mime: String
    )? {
        guard !line.isEmpty, line.range(of: needle) != nil,
            let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
            let message = object["message"] as? [String: Any],
            let blocks = message["content"] as? [[String: Any]]
        else { return nil }
        for block in blocks where block["tool_use_id"] as? String == toolID {
            guard let mime = mime(block: block, result: object["toolUseResult"]),
                let base64 = base64(block: block, result: object["toolUseResult"]),
                let data = Data(base64Encoded: base64)
            else { return nil }
            return (data, mime)
        }
        return nil
    }

    private static func base64(block: [String: Any], result: Any?) -> String? {
        if let result = result as? [String: Any], let file = result["file"] as? [String: Any],
            let base64 = file["base64"] as? String, !base64.isEmpty
        {
            return base64
        }
        guard let inner = block["content"] as? [[String: Any]] else { return nil }
        for item in inner where item["type"] as? String == "image" {
            if let source = item["source"] as? [String: Any],
                let data = source["data"] as? String, !data.isEmpty
            {
                return data
            }
        }
        return nil
    }

    private static func mime(block: [String: Any], result: Any?) -> String? {
        ImageResult.mime(block: block, result: result)
    }
}
