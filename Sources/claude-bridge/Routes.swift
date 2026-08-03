import Foundation
import HTTPTypes
import Hummingbird
import NIOCore
import ServiceLifecycle

/// Enough of a type map to make attachments render inline in a client; the
/// bytes are whatever the client uploaded, so anything unrecognized is opaque.
private func mimeType(forExtension ext: String) -> String {
    switch ext.lowercased() {
    case "jpg", "jpeg": return "image/jpeg"
    case "png": return "image/png"
    case "gif": return "image/gif"
    case "heic": return "image/heic"
    case "webp": return "image/webp"
    case "pdf": return "application/pdf"
    case "txt", "log", "md": return "text/plain; charset=utf-8"
    case "json": return "application/json"
    default: return "application/octet-stream"
    }
}

private func jsonResponse<T: Encodable>(_ value: T, status: HTTPResponse.Status = .ok) -> Response {
    let data = (try? JSONCoding.encoder.encode(value)) ?? Data("{}".utf8)
    var buffer = ByteBuffer()
    buffer.writeBytes(data)
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    return Response(status: status, headers: headers, body: .init(byteBuffer: buffer))
}

/// A prompt the bridge accepted, and whether it is running now or waiting behind a turn already
/// in flight — a client that sent it while another client's turn was running needs to be able to
/// say so rather than showing it as sent-and-ignored.
private struct SendAccepted: Encodable {
    let ok = true
    let queued: Bool
    let position: Int?
}

private struct AbortResult: Encodable {
    let ok = true
    let stopped: Bool
    let discarded: Int
}

private func rawResponse(
    _ data: Data, mime: String?, cacheControl: String = "private, max-age=60"
) -> Response {
    var headers = HTTPFields()
    headers[.contentType] = mime
    headers[.cacheControl] = cacheControl
    var buffer = ByteBuffer()
    buffer.writeBytes(data)
    return Response(status: .ok, headers: headers, body: .init(byteBuffer: buffer))
}

private func decodeBody<T: Decodable>(
    _ type: T.Type, _ request: Request, limit: Int = 1 << 20
) async throws -> T {
    let buffer = try await request.body.collect(upTo: limit)
    return try JSONCoding.decoder.decode(T.self, from: Data(buffer.readableBytesView))
}

private func isValidDeviceToken(_ token: String) -> Bool {
    !token.isEmpty && token.count <= 200 && token.allSatisfy(\.isHexDigit)
}

struct BridgeStatus: Encodable {
    let agent: String
    let model: String
    let version: String
    let authenticated: Bool
    /// Protocol 2: this bridge serves `GET /stream` — one sequenced, replayable event stream.
    let proto: Int
    let epoch: String
}

struct AuthCodeRequest: Decodable {
    let code: String
}

func registerRoutes(
    _ router: Router<BasicRequestContext>, store: SessionStore, index: TranscriptIndex,
    watcher: TranscriptWatcher, updater: UpdateService, auth: AuthService, hub: Hub,
    observer: ObserverLoop, defaults: MachineDefaults, hasAuth: Bool
) {
    @Sendable func adoptIfNeeded(_ id: String) async {
        guard await store.get(id) == nil, let discovered = await index.session(id) else { return }
        _ = await store.adopt(discovered)
    }

    router.get("health") { _, _ in "ok" }

    router.get("status") { _, _ in
        jsonResponse(
            BridgeStatus(
                agent: "claude", model: defaults.model(),
                version: BridgeVersion.describe(source: BridgeVersion.sourceDirectory()),
                authenticated: await auth.status().loggedIn,
                proto: 2, epoch: await hub.epoch))
    }

    /// One sequenced stream of everything: session deltas, list rows, agents, statuses. Every
    /// frame carries `id: <seq>` under the hello's epoch; a client reconnecting with
    /// `Last-Event-ID` (or `?since=epoch:seq`) replays what it missed, or is told `reset` when
    /// that window is gone. Heartbeats every 10 s make silence distinguishable from death.
    router.get("stream") { request, _ in
        var sinceEpoch: String?
        var sinceSeq: UInt64?
        let sinceParam = request.uri.queryParameters.get("since").map { String($0) }
        let cursor =
            request.headers[.init("Last-Event-ID")!].flatMap { $0.isEmpty ? nil : $0 }
            ?? sinceParam
        if let cursor {
            let parts = cursor.split(separator: ":", maxSplits: 1)
            if parts.count == 2, let seq = UInt64(parts[1]) {
                sinceEpoch = String(parts[0])
                sinceSeq = seq
            }
        }
        let attachment = await hub.attach(sinceEpoch: sinceEpoch, sinceSeq: sinceSeq)
        let epoch = await hub.epoch
        let oldest = await hub.oldestReplayableSeq

        let body = ResponseBody { writer in
            func writeFrame(seq: UInt64?, event: String, json: Data) async throws {
                var buffer = ByteBuffer()
                if let seq { buffer.writeString("id: \(epoch):\(seq)\n") }
                buffer.writeString("event: \(event)\ndata: ")
                buffer.writeBytes(json)
                buffer.writeString("\n\n")
                try await writer.write(buffer)
            }
            func encode<Value: Encodable>(_ value: Value) -> Data {
                (try? JSONCoding.encoder.encode(value)) ?? Data("{}".utf8)
            }
            func writeHub(_ frame: HubFrame) async throws {
                switch frame.event {
                case .session(let id, let event):
                    let payload = SessionFramePayload(session: id, event: event)
                    try await writeFrame(seq: frame.seq, event: "session", json: encode(payload))
                case .listUpsert(let summary):
                    try await writeFrame(seq: frame.seq, event: "list.upsert", json: encode(summary))
                case .listRemove(let id):
                    try await writeFrame(
                        seq: frame.seq, event: "list.remove", json: encode(["id": id]))
                case .agents(let sessionID, let agents):
                    let payload = AgentsFramePayload(session: sessionID, agents: agents)
                    try await writeFrame(seq: frame.seq, event: "agents", json: encode(payload))
                case .heartbeat(let seq):
                    try await writeFrame(
                        seq: nil, event: "heartbeat", json: encode(Heartbeat(seq: seq, t: Date())))
                }
            }

            let hello = StreamHello(
                proto: 2, epoch: epoch, seq: attachment.headSeq, oldestSeq: oldest,
                heartbeat: 10, reset: attachment.tooOld)
            try await writeFrame(seq: attachment.headSeq, event: "hello", json: encode(hello))
            for frame in attachment.replay { try await writeHub(frame) }

            try await withGracefulShutdownHandler {
                for await frame in attachment.stream {
                    try await writeHub(frame)
                }
            } onGracefulShutdown: {
                Task { await hub.detach(attachment.id) }
            }
            await hub.detach(attachment.id)
            try await writer.finish(nil)
        }
        var headers = HTTPFields()
        headers[.contentType] = "text/event-stream"
        headers[.cacheControl] = "no-cache"
        return Response(status: .ok, headers: headers, body: body)
    }

    /// Whether the CLI behind this bridge is signed in, and the sign-in in progress if there is
    /// one. A logged-out CLI answers turns with prose instead of failing, so a client has to be
    /// able to ask.
    router.get("auth") { _, _ in
        jsonResponse(await auth.status(refreshing: true))
    }

    /// Starts `claude auth login` on this machine and answers with the URL it printed. The user
    /// opens that on the phone, signs in, and sends the code back to `/auth/code`.
    router.post("auth/login") { _, _ in
        do {
            return jsonResponse(try await auth.beginLogin())
        } catch let error as AuthError {
            return jsonResponse(["error": error.message], status: .badGateway)
        }
    }

    router.post("auth/code") { request, _ in
        guard let body = try? await decodeBody(AuthCodeRequest.self, request) else {
            return jsonResponse(["error": "code required"], status: .badRequest)
        }
        do {
            return jsonResponse(try await auth.submit(code: body.code))
        } catch let error as AuthError {
            return jsonResponse(["error": error.message], status: .badRequest)
        }
    }

    router.post("auth/cancel") { _, _ in
        await auth.cancel()
        return jsonResponse(["ok": true])
    }

    /// What version this bridge runs, whether a newer one exists, and what happened to the last
    /// update — so a client can offer the update rather than leaving a phone user to ssh in.
    router.get("update") { request, _ in
        let refreshing = request.uri.queryParameters.get("check") != "false"
        return jsonResponse(await updater.status(refreshing: refreshing))
    }

    /// Runs the update. Answers immediately with the status to poll: the work outlives this
    /// process, which the restart at the end of it takes down.
    router.post("update") { _, _ in
        let (accepted, status) = await updater.start()
        return jsonResponse(status, status: accepted ? .accepted : .conflict)
    }

    router.get("usage") { _, _ in
        jsonResponse(await ClaudeUsage.snapshot())
    }

    router.get("usage/grok") { _, _ in
        jsonResponse(await GrokUsage.snapshot())
    }

    router.get("usage/opencode") { _, _ in
        jsonResponse(await OpenCodeGoUsage.snapshot())
    }

    router.get("sessions") { _, _ in
        // The observer already computed this within the last second; recomputing per request
        // is what made the route take fifteen seconds under a live turn.
        let warm = await observer.summariesSnapshot()
        if !warm.isEmpty { return jsonResponse(warm) }
        let active = await index.activeIDs(within: TranscriptIndex.activityWindow)
        let dates = await index.transcriptDates()
        let agents = await index.agentActivity()
        let settings = await index.transcriptSettings()
        let stored = await store.list(
            activeClaudeIDs: active, transcriptDates: dates, agents: agents, settings: settings)
        let (claimed, hidden) = await store.excludedTranscriptIDs()
        let discovered = await index.list(excluding: claimed, hidden: hidden)
        return jsonResponse((stored + discovered).sorted { $0.updatedAt > $1.updatedAt })
    }

    router.post("sessions") { request, _ in
        let body = try? await decodeBody(CreateRequest.self, request)
        return jsonResponse(await store.create(body ?? CreateRequest(title: nil, model: nil, effort: nil)))
    }

    router.get("commands") { request, _ in
        let directory = request.uri.queryParameters.get("directory").map { String($0) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return jsonResponse(CommandCatalog.all(home: home, directory: directory))
    }

    router.get("sessions/:id") { _, context in
        let id = context.parameters.get("id") ?? ""
        if var session = await store.get(id) {
            if let partial = await store.liveTurnMessage(id) {
                session.messages.append(partial)
            } else if let claudeID = session.claudeSessionID,
                await !store.hasRunnerTurnInFlight(claudeSessionID: claudeID),
                let transcriptDate = await index.updatedAt(for: claudeID),
                transcriptDate > session.updatedAt.addingTimeInterval(2),
                let fresh = await index.session(claudeID)
            {
                session.messages = fresh.messages
                session.updatedAt = transcriptDate
            }
            // A session with no linked transcript — every fresh chat before its first turn — has
            // nothing the index could say about it: the store id is minted here and the CLI mints
            // its own. Asking anyway queued this GET behind the sweep's fold work, which is where
            // "several seconds to open a brand-new empty chat" actually went.
            if let claudeID = session.claudeSessionID {
                if let observed = await index.transcriptSettings(for: claudeID) {
                    if let model = observed.model { session.model = model }
                    if let effort = observed.effort { session.effort = effort }
                }
                session.goal = await index.goal(for: claudeID)
            }
            return jsonResponse(session)
        }
        if var discovered = await index.session(id) {
            discovered.goal = await index.goal(for: id)
            return jsonResponse(discovered)
        }
        return jsonResponse(["error": "not found"], status: .notFound)
    }

    router.get("files") { request, _ in
        let raw = request.uri.queryParameters.get("path").map { String($0) } ?? "."
        let root = FileManager.default.homeDirectoryForCurrentUser.path
        let path = FileBrowsing.resolve(raw, home: root)
        guard let entries = FileBrowsing.list(path) else {
            return jsonResponse(["error": "not a directory"], status: .notFound)
        }
        return jsonResponse(entries)
    }

    router.get("files/content") { request, _ in
        guard let raw = request.uri.queryParameters.get("path") else {
            return jsonResponse(["error": "path required"], status: .badRequest)
        }
        let root = FileManager.default.homeDirectoryForCurrentUser.path
        let path = FileBrowsing.resolve(String(raw), home: root)
        guard let content = FileBrowsing.content(path) else {
            return jsonResponse(["error": "not readable"], status: .notFound)
        }
        return jsonResponse(FileContent(path: path, content: content))
    }

    /// Bytes of a file the agent worked with, so an image it looked at renders
    /// in the client that cannot reach the host's disk. Same reach as
    /// `/files/content`, which already serves any path this user can read.
    ///
    /// A picture outlives its file: agents write screenshots to `/tmp` and clean
    /// them up, and the conversation still has to show what it was talking
    /// about, so a missing file falls back to the copy the transcript kept for
    /// that tool call. Disk wins when both exist — it holds the picture at full
    /// size, while the transcript keeps the downscaled one the model was sent.
    router.get("files/raw") { request, _ in
        guard let raw = request.uri.queryParameters.get("path") else {
            return jsonResponse(["error": "path required"], status: .badRequest)
        }
        let root = FileManager.default.homeDirectoryForCurrentUser.path
        let path = FileBrowsing.resolve(String(raw), home: root)
        if let data = FileBrowsing.bytes(path) {
            return rawResponse(
                data, mime: mimeType(forExtension: (path as NSString).pathExtension))
        }
        if let tool = request.uri.queryParameters.get("tool"),
            let session = request.uri.queryParameters.get("session"),
            let recovered = await index.imageBytes(session: String(session), toolID: String(tool))
        {
            return rawResponse(recovered.data, mime: recovered.mime)
        }
        return jsonResponse(["error": "not readable"], status: .notFound)
    }

    router.get("attachments/:session/:name") { _, context in
        let session = context.parameters.get("session") ?? ""
        let name = context.parameters.get("name") ?? ""
        guard let url = store.attachmentURL(session: session, name: name),
            let data = try? Data(contentsOf: url)
        else {
            return jsonResponse(["error": "not found"], status: .notFound)
        }
        var headers = HTTPFields()
        headers[.contentType] = mimeType(forExtension: url.pathExtension)
        headers[.cacheControl] = "private, max-age=31536000, immutable"
        var buffer = ByteBuffer()
        buffer.writeBytes(data)
        return Response(status: .ok, headers: headers, body: .init(byteBuffer: buffer))
    }

    router.post("sessions/:id/live-activity") { request, context in
        let id = context.parameters.get("id") ?? ""
        guard let body = try? await decodeBody(LiveActivityRegistration.self, request) else {
            return jsonResponse(["error": "bad request"], status: .badRequest)
        }
        await store.pusher.register(body, sessionID: id)
        return jsonResponse(["ok": true])
    }

    router.post("push/device") { request, _ in
        guard hasAuth else {
            return jsonResponse(
                ["error": "device registration requires BRIDGE_PASSWORD to be set"],
                status: .forbidden)
        }
        guard let body = try? await decodeBody(DeviceRegisterRequest.self, request),
            isValidDeviceToken(body.token),
            body.environment == "development" || body.environment == "production"
        else {
            return jsonResponse(["error": "bad request"], status: .badRequest)
        }
        await store.devicePusher.register(token: body.token, environment: body.environment)
        return jsonResponse(["ok": true])
    }

    router.post("push/device/unregister") { request, _ in
        guard hasAuth else {
            return jsonResponse(
                ["error": "device registration requires BRIDGE_PASSWORD to be set"],
                status: .forbidden)
        }
        guard let body = try? await decodeBody(DeviceRegisterRequest.self, request),
            isValidDeviceToken(body.token)
        else {
            return jsonResponse(["error": "bad request"], status: .badRequest)
        }
        await store.devicePusher.unregister(token: body.token)
        return jsonResponse(["ok": true])
    }

    router.get("sessions/:id/usage") { _, context in
        let id = context.parameters.get("id") ?? ""
        if let session = await store.get(id) {
            return jsonResponse(
                UsageSummary(costUSD: session.lastCostUSD, tokens: session.lastTokens))
        }
        if await index.contains(id) {
            return jsonResponse(UsageSummary(costUSD: nil, tokens: nil))
        }
        return jsonResponse(["error": "not found"], status: .notFound)
    }

    router.patch("sessions/:id") { request, context in
        let id = context.parameters.get("id") ?? ""
        guard let body = try? await decodeBody(RenameRequest.self, request),
            !body.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return jsonResponse(["error": "bad request"], status: .badRequest)
        }
        await adoptIfNeeded(id)
        guard await store.rename(id, title: body.title) else {
            return jsonResponse(["error": "not found"], status: .notFound)
        }
        return jsonResponse(["ok": true])
    }

    router.delete("sessions/:id") { _, context in
        let id = context.parameters.get("id") ?? ""
        let transcripts = await store.ownedTranscriptIDs(id)
        await store.delete(id)
        for transcript in transcripts where await index.contains(transcript) {
            await store.hideTranscript(transcript)
        }
        return jsonResponse(["ok": true])
    }

    router.post("sessions/:id/clear") { _, context in
        let id = context.parameters.get("id") ?? ""
        await adoptIfNeeded(id)
        guard await !store.hasQueuedOrRunningTurn(id) else {
            return jsonResponse(
                [
                    "error":
                        "This session has a turn running. Stop it first, or fork to start clean without interrupting it."
                ],
                status: .conflict)
        }
        await store.clear(id)
        return jsonResponse(["ok": true])
    }

    router.post("sessions/:id/abort") { _, context in
        let id = context.parameters.get("id") ?? ""
        let result = await store.abortTurn(id)
        if result.stopped || result.discarded > 0 {
            return jsonResponse(
                AbortResult(stopped: result.stopped, discarded: result.discarded))
        }
        return jsonResponse(
            [
                "error":
                    "Nothing to stop from here — this session is running on the server, not from this app."
            ],
            status: .conflict)
    }

    router.post("sessions/:id/fork") { _, context in
        let id = context.parameters.get("id") ?? ""
        await adoptIfNeeded(id)
        guard let session = await store.fork(id) else {
            return jsonResponse(["error": "not found"], status: .notFound)
        }
        return jsonResponse(session)
    }

    router.post("sessions/:id/message") { request, context in
        let id = context.parameters.get("id") ?? ""
        guard let body = try? await decodeBody(SendRequest.self, request, limit: 32 << 20) else {
            return jsonResponse(["error": "bad request"], status: .badRequest)
        }
        await adoptIfNeeded(id)
        let claudeID = (await store.get(id))?.claudeSessionID ?? id
        if await !store.recentRunnerActivity(claudeSessionID: claudeID, within: 45),
            await index.isWriting(claudeID, within: 30)
        {
            return jsonResponse(
                [
                    "error":
                        "This session is running on the server right now. Watch it live, or fork to reply without interrupting it."
                ],
                status: .conflict)
        }
        switch await store.send(id, request: body) {
        case .unknownSession:
            return jsonResponse(["error": "not found"], status: .notFound)
        case .started:
            return jsonResponse(SendAccepted(queued: false, position: nil), status: .accepted)
        case .queued(let position):
            return jsonResponse(SendAccepted(queued: true, position: position), status: .accepted)
        }
    }

    router.get("sessions/:id/agents") { _, context in
        let id = context.parameters.get("id") ?? ""
        let claudeID = (await store.get(id))?.claudeSessionID ?? id
        return jsonResponse(await index.subagents(for: claudeID))
    }

    router.get("sessions/:id/agents/:agentID") { _, context in
        let id = context.parameters.get("id") ?? ""
        let agentID = context.parameters.get("agentID") ?? ""
        let claudeID = (await store.get(id))?.claudeSessionID ?? id
        guard let messages = await index.subagentMessages(sessionID: claudeID, agentID: agentID)
        else {
            return jsonResponse(["error": "not found"], status: .notFound)
        }
        return jsonResponse(SubagentTranscript(id: agentID, messages: messages))
    }

    router.get("sessions/:id/events") { _, context in
        let id = context.parameters.get("id") ?? ""
        let caster = await store.broadcaster(for: id)
        let (subscriberID, stream) = caster.subscribe()
        await watcher.ensureTail(sessionID: id)
        let claudeID = (await store.get(id))?.claudeSessionID ?? id
        let running: Bool
        if await store.hasRunnerTurnInFlight(claudeSessionID: claudeID) {
            running = true
        } else if await index.hasWorkingAgents(claudeID) {
            running = true
        } else if let path = await index.path(for: claudeID),
            TranscriptParser.isTurnClosed(atPath: path)
        {
            running = false
        } else {
            running = await index.isWriting(claudeID, within: 30)
        }
        let body = ResponseBody { writer in
            func write(_ event: BridgeEvent) async throws {
                let data = (try? JSONCoding.encoder.encode(event)) ?? Data()
                var buffer = ByteBuffer()
                buffer.writeString("data: ")
                buffer.writeBytes(data)
                buffer.writeString("\n\n")
                try await writer.write(buffer)
            }
            try await write(.status(running ? "running" : "idle"))
            try await withGracefulShutdownHandler {
                for await event in stream {
                    try await write(event)
                }
            } onGracefulShutdown: {
                caster.close(subscriberID)
            }
            try await writer.finish(nil)
        }
        var headers = HTTPFields()
        headers[.contentType] = "text/event-stream"
        headers[.cacheControl] = "no-cache"
        return Response(status: .ok, headers: headers, body: body)
    }
}

struct BasicAuthMiddleware<Context: RequestContext>: RouterMiddleware {
    private let expected: String

    init(username: String, password: String) {
        let raw = Data("\(username):\(password)".utf8).base64EncodedString()
        expected = "Basic \(raw)"
    }

    func handle(
        _ request: Request, context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        guard request.headers[.authorization] == expected else {
            var headers = HTTPFields()
            headers[.wwwAuthenticate] = "Basic realm=\"claude-bridge\""
            return Response(status: .unauthorized, headers: headers)
        }
        return try await next(request, context)
    }
}
