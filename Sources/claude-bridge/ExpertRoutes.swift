import Foundation
import HTTPTypes
import Hummingbird

struct GuardRunRequest: Codable, Sendable {
    var guardID: String?

    private enum CodingKeys: String, CodingKey {
        case guardID = "guard"
    }
}

/// The routes of the experts this machine keeps: the roles themselves, their notebooks, journals,
/// benches and guards, the tasks they start, and the debriefs that close them.
func registerExpertRoutes(_ router: Router<BridgeRequestContext>, experts: ExpertStore) {
    @Sendable func failure(_ error: Error) -> Response {
        switch error {
        case ExpertError.unknown, ExpertError.unknownSession:
            return jsonResponse(["error": String(describing: error)], status: .notFound)
        case ExpertError.busy:
            return jsonResponse(["error": String(describing: error)], status: .conflict)
        default:
            return jsonResponse(["error": String(describing: error)], status: .unprocessableContent)
        }
    }

    @Sendable func id(_ context: BridgeRequestContext) -> String { context.parameters.get("id") ?? "" }

    router.get("experts") { _, _ in
        jsonResponse(await experts.list())
    }

    router.get("experts/skills") { _, _ in
        jsonResponse(experts.skills())
    }

    router.post("experts") { request, _ in
        guard let draft = try? await decodeBody(ExpertDraft.self, request) else {
            return jsonResponse(["error": "name required"], status: .badRequest)
        }
        do {
            let made = try await experts.create(draft)
            await experts.proveBench(made.id)
            return jsonResponse(await experts.get(made.id), status: .created)
        } catch {
            return failure(error)
        }
    }

    router.post("experts/draft") { request, _ in
        guard let body = try? await decodeBody(ExpertDraftRequest.self, request) else {
            return jsonResponse(["error": "session or skill required"], status: .badRequest)
        }
        do {
            return jsonResponse(try await experts.draft(body))
        } catch {
            return failure(error)
        }
    }

    router.get("experts/:id") { request, context in
        if request.uri.queryParameters.get("prove") == "1" { await experts.proveBench(id(context)) }
        guard let view = await experts.get(id(context)) else { return failure(ExpertError.unknown) }
        return jsonResponse(view)
    }

    router.patch("experts/:id") { request, context in
        guard let patch = try? await decodeBody(ExpertPatch.self, request) else {
            return jsonResponse(["error": "nothing to change"], status: .badRequest)
        }
        do {
            _ = try await experts.update(id(context), patch)
            if patch.bench != nil { await experts.proveBench(id(context)) }
            return jsonResponse(await experts.get(id(context)))
        } catch {
            return failure(error)
        }
    }

    router.delete("experts/:id") { _, context in
        guard await experts.delete(id(context)) else { return failure(ExpertError.unknown) }
        return jsonResponse(["ok": true])
    }

    router.get("experts/:id/notebook") { request, context in
        do {
            let retired = request.uri.queryParameters.get("retired") == "1"
            return jsonResponse(try await experts.notes(id(context), retired: retired))
        } catch {
            return failure(error)
        }
    }

    router.get("experts/:id/notebook/:note") { _, context in
        do {
            let raw = context.parameters.get("note") ?? ""
            guard let note = try await experts.note(id(context), raw.removingPercentEncoding ?? raw) else {
                return jsonResponse(["error": "There is no such note."], status: .notFound)
            }
            return jsonResponse(note)
        } catch {
            return failure(error)
        }
    }

    router.get("experts/:id/journal") { _, context in
        do {
            return jsonResponse(try await experts.journal(id(context)))
        } catch {
            return failure(error)
        }
    }

    router.get("experts/:id/brief") { _, context in
        do {
            return jsonResponse(try await experts.preview(id(context)))
        } catch {
            return failure(error)
        }
    }

    router.get("experts/:id/bench") { _, context in
        guard let bench = await experts.proveBench(id(context)) else { return failure(ExpertError.unknown) }
        return jsonResponse(bench)
    }

    router.post("experts/:id/guards/run") { request, context in
        let body = try? await decodeBody(GuardRunRequest.self, request)
        guard await experts.expert(id(context)) != nil else { return failure(ExpertError.unknown) }
        await experts.runGuards(id(context), only: body?.guardID)
        return jsonResponse(await experts.get(id(context)))
    }

    router.post("experts/:id/tasks") { request, context in
        guard let body = try? await decodeBody(ExpertTaskRequest.self, request) else {
            return jsonResponse(["error": "text required"], status: .badRequest)
        }
        do {
            return jsonResponse(try await experts.startTask(id(context), body), status: .created)
        } catch {
            return failure(error)
        }
    }

    router.get("sessions/:id/debrief") { _, context in
        guard let record = await experts.debriefRecord(id(context)) else {
            return jsonResponse(["error": "This task has no debrief yet."], status: .notFound)
        }
        return jsonResponse(record)
    }

    router.post("sessions/:id/debrief") { _, context in
        do {
            return jsonResponse(try await experts.debrief(id(context), wait: false), status: .accepted)
        } catch {
            return failure(error)
        }
    }

    router.post("sessions/:id/debrief/accept") { request, context in
        guard let decision = try? await decodeBody(DebriefDecision.self, request) else {
            return jsonResponse(["error": "accepted required"], status: .badRequest)
        }
        do {
            return jsonResponse(try await experts.decide(id(context), decision))
        } catch {
            return failure(error)
        }
    }
}
