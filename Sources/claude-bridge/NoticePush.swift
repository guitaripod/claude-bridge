import Foundation

/// What a turn-end push carries beyond its English alert: the structured notice the phone's
/// notification extensions draw from, and the `aps` keys that sort and group it. Pure values in,
/// dictionaries out, so nothing here touches the network and every rule is testable alone.
enum NoticePush {
    static let bodyLimit = 3800
    static let textLimit = 700
    static let promptLimit = 400

    enum Kind: String, Sendable {
        case done
        case failed
        case question

        var category: String {
            switch self {
            case .done: return "tailscode.turn"
            case .failed: return "tailscode.turn.failed"
            case .question: return "tailscode.question"
            }
        }

        var relevance: Double {
            switch self {
            case .done: return 0.5
            case .failed: return 0.7
            case .question: return 0.9
            }
        }

        var interruptionLevel: String { self == .question ? "time-sensitive" : "active" }

        /// Reads the kind off the one rule that already decides how a turn ended, so the push can
        /// never disagree with the Live Activity card about a question or a failure.
        init(settled: CardDetail) {
            switch settled {
            case .question, .approval: self = .question
            case .failed, .interrupted, .noResponse, .sendFailed: self = .failed
            default: self = .done
            }
        }
    }

    /// The two halves a push merges into its payload: keys for `aps`, and the `notice` object.
    struct Additions: @unchecked Sendable {
        var kind: Kind
        var aps: [String: Any]
        var notice: [String: Any]
    }

    /// Everything the notice needs from a settled turn. `errorText` is the failure message when
    /// there is one to show; nil leaves `text` out entirely.
    static func additions(
        sessionID: String, messages: [Message], settled: CardDetail, duration: TimeInterval, toolCount: Int,
        prompt: String?, server: String?, errorText: String? = nil
    ) -> Additions {
        let kind = Kind(settled: settled)
        var notice: [String: Any] = [
            "v": 1, "kind": kind.rawValue, "agent": "claudeCode",
            "seconds": max(0, Int(duration.rounded())), "tools": toolCount,
        ]
        let tally = lineTally(of: messages)
        if tally.added > 0 || tally.removed > 0 {
            notice["added"] = tally.added
            notice["removed"] = tally.removed
        }
        if let server, !server.isEmpty { notice["server"] = server }
        switch kind {
        case .done:
            if let text = lastAssistantText(in: messages) { notice["text"] = clipped(text, to: textLimit) }
        case .failed:
            if let errorText { notice["text"] = clipped(errorText, to: textLimit) }
            if let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                prompt.count <= promptLimit
            {
                notice["prompt"] = prompt
            }
        case .question:
            if let question = pendingQuestion(in: messages) {
                notice["text"] = clipped(question.text, to: textLimit)
                if let options = question.options {
                    notice["options"] = options
                    notice["multiple"] = question.multiple
                    notice["free"] = true
                }
            }
        }
        let aps: [String: Any] = [
            "category": kind.category,
            "relevance-score": kind.relevance,
            "target-content-id": sessionID,
            "interruption-level": kind.interruptionLevel,
        ]
        return Additions(kind: kind, aps: aps, notice: notice)
    }

    /// Lays the additions over a payload whose `aps` the pusher already wrote, leaving every key
    /// that was there in place except the interruption level a question raises.
    static func merged(_ payload: [String: Any], with additions: Additions) -> [String: Any] {
        var result = payload
        var aps = result["aps"] as? [String: Any] ?? [:]
        for (key, value) in additions.aps { aps[key] = value }
        result["aps"] = aps
        result["notice"] = additions.notice
        return result
    }

    /// Brings the serialized payload under `limit` bytes by giving up the least valuable part of
    /// the notice first: the answer text is halved until it fits, then the prompt goes, then the
    /// options lose their descriptions, then the text goes, and last the options themselves.
    static func fitted(_ payload: [String: Any], limit: Int = bodyLimit) -> [String: Any] {
        guard var notice = payload["notice"] as? [String: Any] else { return payload }
        var result = payload
        func fits() -> Bool {
            result["notice"] = notice
            return size(of: result) <= limit
        }
        if fits() { return result }
        while var text = notice["text"] as? String, text.count > 16, !fits() {
            text = String(text.prefix(text.count / 2)).trimmingCharacters(in: .whitespacesAndNewlines)
                + "…"
            notice["text"] = text
        }
        if fits() { return result }
        notice["prompt"] = nil
        if fits() { return result }
        if let options = notice["options"] as? [[String: Any]] {
            notice["options"] = options.map { ["label": $0["label"] ?? ""] }
            if fits() { return result }
        }
        notice["text"] = nil
        if fits() { return result }
        notice["options"] = nil
        notice["multiple"] = nil
        notice["free"] = nil
        _ = fits()
        return result
    }

    static func size(of payload: [String: Any]) -> Int {
        (try? JSONSerialization.data(withJSONObject: payload))?.count ?? 0
    }

    static let serverName: String? = {
        let name = ProcessInfo.processInfo.hostName.replacingOccurrences(of: ".local", with: "")
        return name.isEmpty ? nil : name
    }()

    /// The text of the newest assistant text part that says anything.
    static func lastAssistantText(in messages: [Message]) -> String? {
        for message in messages.reversed() where message.role == .assistant {
            for part in message.parts.reversed() {
                guard case .text(let value) = part else { continue }
                if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return value }
            }
        }
        return nil
    }

    /// The text of the newest user message, which is the prompt that began the turn.
    static func lastUserPrompt(in messages: [Message]) -> String? {
        for message in messages.reversed() where message.role == .user {
            let text = message.parts.compactMap { part -> String? in
                if case .text(let value) = part { return value }
                return nil
            }.joined(separator: "\n")
            return text
        }
        return nil
    }

    /// Lines the turn's finished edits and writes added and removed, counted the way the app's
    /// diff counts them: an edit's old string is removed and its new string added, a write's
    /// content is added.
    static func lineTally(of messages: [Message]) -> (added: Int, removed: Int) {
        var added = 0
        var removed = 0
        for message in messages {
            for part in message.parts {
                guard case .tool(let call) = part, call.status == .completed,
                    let input = jsonObject(call.input)
                else { continue }
                switch call.name.lowercased() {
                case "edit":
                    removed += lineCount(input["old_string"])
                    added += lineCount(input["new_string"])
                case "multiedit":
                    for edit in input["edits"] as? [[String: Any]] ?? [] {
                        removed += lineCount(edit["old_string"])
                        added += lineCount(edit["new_string"])
                    }
                case "write":
                    added += lineCount(input["content"])
                default:
                    continue
                }
            }
        }
        return (added, removed)
    }

    private struct PendingQuestion {
        var text: String
        var options: [[String: Any]]?
        var multiple: Bool
    }

    /// The question the turn is waiting on, read from the newest unanswered `AskUserQuestion`
    /// call. Options are offered only for a single question, since a card cannot answer several.
    private static func pendingQuestion(in messages: [Message]) -> PendingQuestion? {
        for message in messages.reversed() where message.role == .assistant {
            for part in message.parts.reversed() {
                guard case .tool(let call) = part,
                    call.name.caseInsensitiveCompare("AskUserQuestion") == .orderedSame
                else { continue }
                guard let input = jsonObject(call.input),
                    let questions = input["questions"] as? [[String: Any]],
                    let first = questions.first, let text = first["question"] as? String
                else { return nil }
                guard questions.count == 1 else {
                    return PendingQuestion(text: text, options: nil, multiple: false)
                }
                let options: [[String: Any]] = (first["options"] as? [[String: Any]] ?? [])
                    .compactMap { option in
                        guard let label = option["label"] as? String, !label.isEmpty else {
                            return nil
                        }
                        var entry: [String: Any] = ["label": label]
                        if let detail = option["description"] as? String, !detail.isEmpty {
                            entry["detail"] = detail
                        }
                        return entry
                    }
                return PendingQuestion(
                    text: text, options: options.isEmpty ? nil : options,
                    multiple: first["multiSelect"] as? Bool ?? false)
            }
        }
        return nil
    }

    private static func jsonObject(_ input: String) -> [String: Any]? {
        guard let data = input.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func lineCount(_ value: Any?) -> Int {
        guard let text = value as? String, !text.isEmpty else { return 0 }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines.count
    }

    private static func clipped(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 1)) + "…"
    }
}
