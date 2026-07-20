import Foundation
import HTTPTypes
import Hummingbird
import NIOCore

private func jsonResponse<T: Encodable>(_ value: T, status: HTTPResponse.Status = .ok) -> Response {
    let data = (try? JSONCoding.encoder.encode(value)) ?? Data("{}".utf8)
    var buffer = ByteBuffer()
    buffer.writeBytes(data)
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    return Response(status: status, headers: headers, body: .init(byteBuffer: buffer))
}

private func decodeBody<T: Decodable>(_ type: T.Type, _ request: Request) async throws -> T {
    let buffer = try await request.body.collect(upTo: 1 << 20)
    return try JSONCoding.decoder.decode(T.self, from: Data(buffer.readableBytesView))
}

private func isValidDeviceToken(_ token: String) -> Bool {
    !token.isEmpty && token.count <= 200 && token.allSatisfy(\.isHexDigit)
}

func registerRoutes(
    _ router: Router<BasicRequestContext>, store: SessionStore, index: TranscriptIndex,
    watcher: TranscriptWatcher, agentModel: String, hasAuth: Bool
) {
    @Sendable func adoptIfNeeded(_ id: String) async {
        guard await store.get(id) == nil, let discovered = await index.session(id) else { return }
        _ = await store.adopt(discovered)
    }

    router.get("health") { _, _ in "ok" }

    router.get("status") { _, _ in
        jsonResponse(["agent": "claude", "model": agentModel])
    }

    router.get("usage") { _, _ in
        jsonResponse(await ClaudeUsage.snapshot())
    }

    router.get("usage/grok") { _, _ in
        jsonResponse(await GrokUsage.snapshot())
    }

    router.get("sessions") { _, _ in
        let active = await index.activeIDs(within: TranscriptIndex.activityWindow)
        let dates = await index.transcriptDates()
        let stored = await store.list(activeClaudeIDs: active, transcriptDates: dates)
        let (claimed, hidden) = await store.excludedTranscriptIDs()
        let discovered = await index.list(excluding: claimed, hidden: hidden)
        return jsonResponse((stored + discovered).sorted { $0.updatedAt > $1.updatedAt })
    }

    router.post("sessions") { request, _ in
        let body = try? await decodeBody(CreateRequest.self, request)
        return jsonResponse(await store.create(body ?? CreateRequest(title: nil, model: nil, effort: nil)))
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
            return jsonResponse(session)
        }
        if let discovered = await index.session(id) {
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
        await store.clear(id)
        return jsonResponse(["ok": true])
    }

    router.post("sessions/:id/abort") { _, context in
        let id = context.parameters.get("id") ?? ""
        if await store.abortTurn(id) {
            return jsonResponse(["ok": true])
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
        guard let body = try? await decodeBody(SendRequest.self, request) else {
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
        await store.send(id, request: body)
        return jsonResponse(["ok": true], status: .accepted)
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
        let (_, stream) = caster.subscribe()
        await watcher.ensureTail(sessionID: id)
        let claudeID = (await store.get(id))?.claudeSessionID ?? id
        let running: Bool
        if await store.hasRunnerTurnInFlight(claudeSessionID: claudeID) {
            running = true
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
            for await event in stream {
                try await write(event)
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
