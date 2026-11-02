import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// A model server already running on this machine that an agent could think with: anything that
/// answers the OpenAI `/v1/models` route on one of the ports such servers use.
struct LocalBrain: Codable, Sendable, Equatable {
    struct Model: Codable, Sendable, Equatable {
        var id: String
        var name: String
    }

    var id: String
    var name: String
    var baseURL: String
    var models: [Model]
}

enum BrainFinder {
    /// The usual homes of a local model server: ollama, llama-swap and llama-server, LM Studio,
    /// vLLM and SGLang. `BRIDGE_BRAINS` adds more, as base URLs separated by commas.
    static let ports = [11434, 8080, 8081, 1234, 8000, 30000]

    static func find(timeout: TimeInterval = 1.5) async -> [LocalBrain] {
        var bases = ports.map { "http://127.0.0.1:\($0)/v1" }
        if let extra = ProcessInfo.processInfo.environment["BRIDGE_BRAINS"] {
            bases += extra.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }
        }
        let found = await withTaskGroup(of: (Int, LocalBrain?).self) { group in
            for (index, base) in bases.enumerated() {
                group.addTask { (index, await probe(base: base, timeout: timeout)) }
            }
            var out: [(Int, LocalBrain)] = []
            for await (index, brain) in group {
                if let brain { out.append((index, brain)) }
            }
            return out.sorted { $0.0 < $1.0 }.map(\.1)
        }
        var seen: Set<String> = []
        return found.filter { seen.insert($0.baseURL).inserted }
    }

    static func probe(base: String, timeout: TimeInterval) async -> LocalBrain? {
        guard let url = URL(string: base.hasSuffix("/") ? base + "models" : base + "/models") else {
            return nil
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return read(data, base: base)
    }

    /// The models a server lists, named the way it names them. A llama-swap whose entries mark the
    /// ones meant for agents (`meta.llamaswap.agent`) is read for those alone: the rest are filters
    /// and phone twins nobody would hand an agent.
    static func read(_ data: Data, base: String) -> LocalBrain? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rows = object["data"] as? [[String: Any]]
        else { return nil }
        let marked = rows.filter { Self.agentMark($0) }
        let chosen = marked.isEmpty ? rows : marked
        let models: [LocalBrain.Model] = chosen.compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            let name = (row["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
            return LocalBrain.Model(id: id, name: name)
        }
        guard !models.isEmpty else { return nil }
        let server = Self.serverName(rows: rows, base: base)
        return LocalBrain(
            id: server.lowercased().replacingOccurrences(of: " ", with: "-"), name: server,
            baseURL: base, models: models)
    }

    private static func agentMark(_ row: [String: Any]) -> Bool {
        guard let meta = row["meta"] as? [String: Any],
            let swap = meta["llamaswap"] as? [String: Any]
        else { return false }
        return swap["agent"] != nil
    }

    private static func serverName(rows: [[String: Any]], base: String) -> String {
        if rows.contains(where: { ($0["meta"] as? [String: Any])?["llamaswap"] != nil }) {
            return "llama-swap"
        }
        let owners = Set(rows.compactMap { ($0["owned_by"] as? String)?.lowercased() })
        if owners.contains("vllm") { return "vLLM" }
        if owners.contains("sglang") { return "SGLang" }
        if owners.contains("library") || base.contains(":11434") { return "ollama" }
        if base.contains(":1234") { return "LM Studio" }
        if owners.contains("llamacpp") { return "llama.cpp" }
        let port = URL(string: base)?.port.map { ":\($0)" } ?? ""
        return "Local server \(port)"
    }
}
