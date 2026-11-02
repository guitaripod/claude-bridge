import json
import os
import sys

sessions = {}
pending_permission = {}
next_id = [1000]


def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def update(session_id, body):
    send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": session_id, "update": body}})


def models():
    return {"availableModels": [{"modelId": "fast", "name": "Fast"}, {"modelId": "deep", "name": "Deep"}], "currentModelId": "fast"}


def config():
    return [{"id": "effort", "name": "Effort", "category": "thought_level", "type": "select", "currentValue": "low",
             "options": [{"value": "low", "name": "Low"}, {"value": "high", "name": "High"}]}]


def answer_prompt(request_id, session_id, text):
    if "QUIET" in text and "NOTHING NEW" in text:
        update(session_id, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "NOTHING NEW"}})
        send({"jsonrpc": "2.0", "id": request_id, "result": {"stopReason": "end_turn"}})
        return
    if "FAIL" in text:
        send({"jsonrpc": "2.0", "id": request_id, "error": {"code": -32603, "message": "Internal error", "data": {"details": "the fake agent was told to fail"}}})
        return
    update(session_id, {"sessionUpdate": "agent_thought_chunk", "content": {"type": "text", "text": "thinking about it"}})
    update(session_id, {"sessionUpdate": "plan", "entries": [{"content": "Look", "priority": "high", "status": "completed"}, {"content": "Answer", "priority": "high", "status": "in_progress"}]})
    update(session_id, {"sessionUpdate": "tool_call", "toolCallId": "tc-1", "title": "terminal: uname -s", "kind": "execute", "status": "pending", "content": []})
    next_id[0] += 1
    permission_id = next_id[0]
    pending_permission[permission_id] = (request_id, session_id, text)
    send({"jsonrpc": "2.0", "id": permission_id, "method": "session/request_permission", "params": {
        "sessionId": session_id,
        "toolCall": {"toolCallId": "tc-1"},
        "options": [{"optionId": "deny", "name": "Deny", "kind": "reject_once"}, {"optionId": "yes", "name": "Allow", "kind": "allow_once"}],
    }})


def finish_prompt(request_id, session_id, text, allowed):
    update(session_id, {"sessionUpdate": "tool_call_update", "toolCallId": "tc-1", "status": "completed" if allowed else "failed",
                        "content": [{"type": "content", "content": {"type": "text", "text": "Linux" if allowed else "denied"}}]})
    update(session_id, {"sessionUpdate": "session_info_update", "title": "Fake titled chat"})
    reply = "model=%s effort=%s you said: %s" % (sessions[session_id]["model"], sessions[session_id]["effort"], text.splitlines()[0])
    for piece in [reply[:10], reply[10:]]:
        update(session_id, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": piece}})
    send({"jsonrpc": "2.0", "id": request_id, "result": {"stopReason": "end_turn"}})


for line in sys.stdin:
    message = json.loads(line)
    method = message.get("method")
    if method is None and message.get("id") in pending_permission:
        request_id, session_id, text = pending_permission.pop(message["id"])
        outcome = message.get("result", {}).get("outcome", {})
        finish_prompt(request_id, session_id, text, outcome.get("optionId") == "yes")
        continue
    request_id = message.get("id")
    params = message.get("params", {})
    if method == "initialize":
        auth = [{"id": "fake-login", "name": "Log in", "type": "terminal", "args": ["--login"]}]
        send({"jsonrpc": "2.0", "id": request_id, "result": {"protocolVersion": 1, "agentInfo": {"name": "fake-agent", "version": "9.9.9"},
              "agentCapabilities": {"loadSession": True, "sessionCapabilities": {"resume": {}}}, "authMethods": auth}})
    elif method == "session/new":
        if os.environ.get("FAKE_NEEDS_PROVIDER") and not os.environ.get("FAKE_PROVIDER"):
            send({"jsonrpc": "2.0", "id": request_id, "error": {"code": -32603, "message": "Internal error", "data": {"details": "No LLM provider configured. Run `fake model`."}}})
            continue
        session_id = "fake-%d" % (len(sessions) + 1)
        sessions[session_id] = {"model": "fast", "effort": "low"}
        send({"jsonrpc": "2.0", "id": request_id, "result": {"sessionId": session_id, "models": models(), "configOptions": config()}})
    elif method == "session/resume":
        session_id = params["sessionId"]
        sessions.setdefault(session_id, {"model": "fast", "effort": "low"})
        send({"jsonrpc": "2.0", "id": request_id, "result": {"models": models(), "configOptions": config()}})
    elif method == "session/set_model":
        sessions[params["sessionId"]]["model"] = params["modelId"]
        send({"jsonrpc": "2.0", "id": request_id, "result": {}})
    elif method == "session/set_config_option":
        sessions[params["sessionId"]]["effort"] = params["value"]
        send({"jsonrpc": "2.0", "id": request_id, "result": {"configOptions": config()}})
    elif method == "session/prompt":
        text = "".join(block.get("text", "") for block in params.get("prompt", []))
        answer_prompt(request_id, params["sessionId"], text)
    elif method == "session/cancel":
        pass
    elif request_id is not None:
        send({"jsonrpc": "2.0", "id": request_id, "error": {"code": -32601, "message": "Method not found"}})
