import Foundation
import HTTPTypes
import Hummingbird

struct AgentKeyRequest: Codable, Sendable {
    var env: String
    var value: String
}

struct AgentSignInRequest: Codable, Sendable {
    var method: String?
}

struct AgentSignInInput: Codable, Sendable {
    var text: String
}

struct AgentInstallRequest: Codable, Sendable {
    var id: String
}

/// The routes that are about the machine rather than one conversation: the ACP agents it hosts
/// beside Claude, and the schedules it keeps.
func registerMachineRoutes(
    _ router: Router<BridgeRequestContext>, agents: AgentService, scheduler: Scheduler
) {
    @Sendable func failure(_ error: Error) -> Response {
        jsonResponse(["error": String(describing: error)], status: .unprocessableContent)
    }

    @Sendable func agentID(_ context: BridgeRequestContext) -> String {
        context.parameters.get("id") ?? ""
    }

    router.get("agents") { request, _ in
        let refresh = request.uri.queryParameters.get("refresh") == "1"
        return jsonResponse(await agents.report(refreshBrains: refresh))
    }

    router.get("agents/registry") { _, _ in
        jsonResponse(await agents.registryRows())
    }

    router.get("agents/models") { _, _ in
        jsonResponse(await agents.modelRows())
    }

    router.post("agents/install") { request, _ in
        guard let body = try? await decodeBody(AgentInstallRequest.self, request) else {
            return jsonResponse(["error": "id required"], status: .badRequest)
        }
        do {
            return jsonResponse(try await agents.install(body.id))
        } catch {
            return failure(error)
        }
    }

    router.post("agents/:id/add") { _, context in
        do {
            return jsonResponse(try await agents.add(agentID(context)))
        } catch {
            return failure(error)
        }
    }

    router.post("agents/:id/remove") { _, context in
        await agents.remove(agentID(context))
        return jsonResponse(["ok": true])
    }

    router.post("agents/:id/check") { _, context in
        do {
            return jsonResponse(try await agents.check(agentID(context)))
        } catch {
            return failure(error)
        }
    }

    router.post("agents/:id/key") { request, context in
        guard let body = try? await decodeBody(AgentKeyRequest.self, request) else {
            return jsonResponse(["error": "env and value required"], status: .badRequest)
        }
        do {
            return jsonResponse(try await agents.setKey(agentID(context), env: body.env, value: body.value))
        } catch {
            return failure(error)
        }
    }

    router.post("agents/:id/brain") { request, context in
        guard let body = try? await decodeBody(BrainRequest.self, request) else {
            return jsonResponse(["error": "kind required"], status: .badRequest)
        }
        do {
            return jsonResponse(try await agents.setBrain(agentID(context), body))
        } catch {
            return failure(error)
        }
    }

    router.post("agents/:id/signin") { request, context in
        let body = try? await decodeBody(AgentSignInRequest.self, request)
        do {
            return jsonResponse(
                try await agents.startSignIn(agentID(context), method: body?.method ?? ""))
        } catch {
            return failure(error)
        }
    }

    router.get("agents/:id/signin") { _, context in
        guard let state = await agents.signInState(agentID(context)) else {
            return jsonResponse(["error": "No sign-in is running for this agent."], status: .notFound)
        }
        return jsonResponse(state)
    }

    router.post("agents/:id/signin/input") { request, context in
        guard let body = try? await decodeBody(AgentSignInInput.self, request) else {
            return jsonResponse(["error": "text required"], status: .badRequest)
        }
        await agents.signInInput(agentID(context), text: body.text)
        return jsonResponse(["ok": true])
    }

    router.post("agents/:id/signin/cancel") { _, context in
        await agents.cancelSignIn(agentID(context))
        return jsonResponse(["ok": true])
    }

    router.get("schedules") { _, _ in
        jsonResponse(await scheduler.list())
    }

    router.post("schedules") { request, _ in
        guard let draft = try? await decodeBody(ScheduleDraft.self, request) else {
            return jsonResponse(["error": "text and rule required"], status: .badRequest)
        }
        do {
            return jsonResponse(try await scheduler.create(draft), status: .created)
        } catch {
            return failure(error)
        }
    }

    router.get("schedules/:id") { _, context in
        guard let schedule = await scheduler.schedule(context.parameters.get("id") ?? "") else {
            return jsonResponse(["error": ScheduleError.unknown.description], status: .notFound)
        }
        return jsonResponse(schedule)
    }

    router.patch("schedules/:id") { request, context in
        guard let patch = try? await decodeBody(SchedulePatch.self, request) else {
            return jsonResponse(["error": "nothing to change"], status: .badRequest)
        }
        do {
            return jsonResponse(try await scheduler.update(context.parameters.get("id") ?? "", patch))
        } catch ScheduleError.unknown {
            return jsonResponse(["error": ScheduleError.unknown.description], status: .notFound)
        } catch {
            return failure(error)
        }
    }

    router.delete("schedules/:id") { _, context in
        guard await scheduler.delete(context.parameters.get("id") ?? "") else {
            return jsonResponse(["error": ScheduleError.unknown.description], status: .notFound)
        }
        return jsonResponse(["ok": true])
    }

    router.post("schedules/:id/run") { _, context in
        do {
            return jsonResponse(try await scheduler.runNow(context.parameters.get("id") ?? ""))
        } catch ScheduleError.unknown {
            return jsonResponse(["error": ScheduleError.unknown.description], status: .notFound)
        } catch {
            return failure(error)
        }
    }
}
