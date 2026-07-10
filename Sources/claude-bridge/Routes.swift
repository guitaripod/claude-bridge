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

func registerRoutes(
    _ router: Router<BasicRequestContext>, store: SessionStore, index: TranscriptIndex,
    agentModel: String
) {
    @Sendable func adoptIfNeeded(_ id: String) async {
        guard await store.get(id) == nil, let discovered = await index.session(id) else { return }
        _ = await store.adopt(discovered)
    }

    router.get("health") { _, _ in "ok" }

    router.get("status") { _, _ in
        jsonResponse(["agent": "claude", "model": agentModel])
    }

    router.get("sessions") { _, _ in
        let stored = await store.list()
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
        if let session = await store.get(id) {
            return jsonResponse(session)
        }
        if let discovered = await index.session(id) {
            return jsonResponse(discovered)
        }
        return jsonResponse(["error": "not found"], status: .notFound)
    }

    router.delete("sessions/:id") { _, context in
        let id = context.parameters.get("id") ?? ""
        await store.delete(id)
        if await index.contains(id) {
            await store.hideTranscript(id)
        }
        return jsonResponse(["ok": true])
    }

    router.post("sessions/:id/clear") { _, context in
        let id = context.parameters.get("id") ?? ""
        await adoptIfNeeded(id)
        await store.clear(id)
        return jsonResponse(["ok": true])
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
        await store.send(id, request: body)
        return jsonResponse(["ok": true], status: .accepted)
    }

    router.get("sessions/:id/events") { _, context in
        let id = context.parameters.get("id") ?? ""
        let caster = await store.broadcaster(for: id)
        let (_, stream) = caster.subscribe()
        let body = ResponseBody { writer in
            for await event in stream {
                let data = (try? JSONCoding.encoder.encode(event)) ?? Data()
                var buffer = ByteBuffer()
                buffer.writeString("data: ")
                buffer.writeBytes(data)
                buffer.writeString("\n\n")
                try await writer.write(buffer)
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
