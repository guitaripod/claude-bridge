import json
import os
import sys

"""Speaks ACP the way Antigravity CLI 1.5 does, in the shapes its `agy acp` was recorded sending.

State lives under FAKE_AGY_HOME so it survives the process, as the real CLI's does:
  method      the sign-in method `authenticate` chose
  signed-in   written by `--login` when the code is right
  sessions    one file per session: the notes its system prompt was given and any question left open
"""

home = os.environ.get("FAKE_AGY_HOME", "/tmp")
os.makedirs(os.path.join(home, "sessions"), exist_ok=True)

LEVELS = {"fast": ["low", "high"], "deep": ["low", "medium", "high", "xhigh"]}
live = {}
waiting = {}
sleeping = {}
next_id = [5000]


def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def update(session_id, body):
    send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": session_id, "update": body}})


def chunk(session_id, text):
    update(session_id, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}})


def read(name):
    try:
        return open(os.path.join(home, name)).read().strip()
    except OSError:
        return ""


def write(name, text):
    with open(os.path.join(home, name), "w") as handle:
        handle.write(text)


def stored(session_id):
    try:
        return json.load(open(os.path.join(home, "sessions", session_id + ".json")))
    except (OSError, ValueError):
        return None


def store(session_id, record):
    with open(os.path.join(home, "sessions", session_id + ".json"), "w") as handle:
        json.dump(record, handle)


def signed_in():
    if read("signed-in"):
        return True
    return read("method") == "gemini-api-key" and bool(os.environ.get("GEMINI_API_KEY"))


def login():
    sys.stdout.write("Open this link in a browser to log in with Google:\n\n")
    sys.stdout.write("  https://accounts.google.com/o/oauth2/auth?client_id=fake&state=abc\n\n")
    sys.stdout.write("Then paste the authorization code, or the full URL of the page you land on, and press Enter:\n")
    sys.stdout.flush()
    code = sys.stdin.readline().strip()
    if code == "good-code":
        write("signed-in", "yes")
        write("method", "oauth-personal")
        sys.exit(0)
    sys.stdout.write('\ncouldn\'t log in: token exchange failed: oauth2: "invalid_grant" "Malformed auth code."\n')
    sys.exit(1)


def choices(session):
    pairings = [{"modelId": "%s-%s" % (model, level), "name": "%s (%s)" % (model.title(), level.title())}
                for model in LEVELS for level in LEVELS[model]]
    return {
        "models": {"availableModels": pairings, "currentModelId": "%s-%s" % (session["model"], session["effort"])},
        "modes": {"currentModeId": "default", "availableModes": [{"id": "default", "name": "Default"}]},
        "configOptions": options(session),
    }


def options(session):
    return [
        {"id": "model", "name": "Model", "category": "model", "type": "select", "currentValue": session["model"],
         "options": [{"value": "deep", "name": "Deep"}, {"value": "fast", "name": "Fast"}]},
        {"id": "thought_level", "name": "Thinking Level", "category": "thought_level", "type": "select",
         "currentValue": session["effort"],
         "options": [{"value": level, "name": level.title()} for level in LEVELS[session["model"]]]},
        {"id": "mode", "name": "Mode", "category": "mode", "type": "select", "currentValue": "default",
         "options": [{"value": "default", "name": "Default"}]},
    ]


def call(session_id, kind, call_id, name, args, status, title, extra=None):
    body = {"sessionUpdate": kind, "toolCallId": call_id, "name": name, "args": args, "status": status,
            "kind": {"run_command": "execute", "write_file": "edit", "edit_file": "edit", "read_file": "read",
                     "search_web": "search"}.get(name, "other"),
            "title": title, "rawInput": args}
    body.update(extra or {})
    update(session_id, body)


def run_command(session_id, call_id, command, summary, output, code):
    args = {"CommandLine": command, "WaitMsBeforeAsync": 5000, "toolSummary": summary}
    call(session_id, "tool_call", call_id, "run_command", args, "in_progress", command)
    call(session_id, "tool_call_update", call_id, "run_command", args, "pending", command)
    receipt = "Created At: 2026-11-28T06:51:21+02:00\nCompleted At: 2026-11-28T06:51:21+02:00\nCommand exited with code %d.\n\nCommand output:\n%s\r\n" % (code, output)
    call(session_id, "tool_call_update", call_id, "run_command", args, "completed", command, {
        "rawOutput": {"output": receipt, "exit_code": code},
        "content": [{"type": "content", "content": {"type": "text", "text": receipt}}]})


def finish(request_id, reason="end_turn"):
    send({"jsonrpc": "2.0", "id": request_id, "result": {
        "stopReason": reason,
        "usage": {"inputTokens": 1200, "outputTokens": 30, "cachedReadTokens": 0, "cachedWriteTokens": 0,
                  "thoughtTokens": 0, "totalTokens": 1230}}})


def prompt(request_id, session_id, text):
    session = live[session_id]
    record = stored(session_id) or {"notes": []}
    asked = record.pop("asked", None)
    if asked:
        store(session_id, record)
        call(session_id, "tool_call_update", asked["id"], "ask_question", asked["args"], "in_progress", "Run ask_question")
        call(session_id, "tool_call_update", asked["id"], "ask_question", asked["args"], "completed", "Run ask_question")
        chunk(session_id, "answered: " + text.splitlines()[0])
        finish(request_id)
        return
    if "ASK" in text:
        args = {"questions": [
            {"question": "Which database should the service use?", "options": ["(Recommended) Postgres", "SQLite"]},
            {"question": "Which features do you want?", "options": ["Auth", "Search"], "is_multi_select": True}]}
        chunk(session_id, "I need to know one thing first.")
        call(session_id, "tool_call", "ask-1", "ask_question", args, "in_progress", "Run ask_question")
        call(session_id, "tool_call_update", "ask-1", "ask_question", args, "pending", "Run ask_question")
        chunk(session_id, "\nWhich database should the service use?\n- [1] (Recommended) Postgres\n- [2] SQLite\n\nWhich features do you want?\n- [1] Auth\n- [2] Search\n")
        record["asked"] = {"id": "ask-1", "args": args}
        store(session_id, record)
        finish(request_id)
        return
    if "QUOTA" in text:
        if "PARTIAL" in text:
            chunk(session_id, "Half an answer.")
        chunk(session_id, "\n⚠ agent executor error: generating and executing: Error 429, Message: You have exhausted your capacity on this model., Status: RESOURCE_EXHAUSTED, Details: []\n")
        send({"jsonrpc": "2.0", "id": request_id, "result": {"stopReason": "end_turn"}})
        return
    if "SLEEP" in text:
        args = {"CommandLine": "sleep 60", "WaitMsBeforeAsync": 10000, "toolSummary": "Long sleep"}
        call(session_id, "tool_call", "sleep-1", "run_command", args, "in_progress", "sleep 60")
        sleeping[session_id] = (request_id, args)
        return
    if "TOUR" in text:
        update(session_id, {"sessionUpdate": "agent_thought_chunk", "content": {"type": "text", "text": "I will run a command first."}})
        chunk(session_id, "Starting the tour.")
        run_command(session_id, "run-1", "echo hello > out.txt && cat out.txt", "Write greeting file", "hello", 0)
        path = "/work/notes.md"
        written = {"Content": "# Notes\n\nfirst line\n", "Path": path}
        call(session_id, "tool_call", "write-1", "write_file", written, "in_progress", "File work/notes.md", {"locations": [{"path": path}]})
        call(session_id, "tool_call_update", "write-1", "write_file", written, "completed", "File work/notes.md", {
            "locations": [{"path": path}], "rawOutput": {},
            "content": [{"type": "diff", "path": path, "newText": "# Notes\n\nfirst line\n"}]})
        edited = {"Path": path, "Replacement": "first line, edited", "Target": "first line"}
        call(session_id, "tool_call", "edit-1", "edit_file", edited, "in_progress", "File work/notes.md", {"locations": [{"path": path}]})
        call(session_id, "tool_call_update", "edit-1", "edit_file", edited, "completed", "File work/notes.md", {
            "locations": [{"path": path}], "rawOutput": {},
            "content": [{"type": "diff", "path": path, "newText": "# Notes\n\nfirst line, edited\n", "oldText": "# Notes\n\nfirst line\n"}]})
        steps = {"steps": [{"status": "done", "title": "Write greeting"}, {"status": "in_progress", "title": "Edit notes"},
                           {"status": "skipped", "title": "Ask around"}, {"status": "pending", "title": "Report back"}]}
        call(session_id, "tool_call", "steps-1", "update_steps", steps, "in_progress", "Run update_steps")
        call(session_id, "tool_call_update", "steps-1", "update_steps", steps, "completed", "Run update_steps")
        run_command(session_id, "run-2", "ls /definitely/not/here", "List missing folder",
                    "ls: cannot access '/definitely/not/here': No such file or directory", 2)
        update(session_id, {"sessionUpdate": "session_info_update", "title": "A tour of the tools"})
        chunk(session_id, "\n\nTour finished.")
        finish(request_id)
        return
    chunk(session_id, "model=%s effort=%s notes=%d you said: %s" % (
        session["model"], session["effort"], len(record.get("notes", [])), text.splitlines()[0]))
    finish(request_id)


if "--login" in sys.argv:
    login()

terminal_auth = [False]
for line in sys.stdin:
    message = json.loads(line)
    method = message.get("method")
    request_id = message.get("id")
    params = message.get("params", {})
    if method is None:
        continue
    if method == "initialize":
        terminal_auth[0] = bool(params.get("clientCapabilities", {}).get("auth", {}).get("terminal"))
        methods = [
            {"id": "oauth-personal", "name": "Log in with Google", "description": "Log in with your Google account"},
            {"id": "gemini-api-key", "name": "Gemini API key", "description": "Use an API key with Gemini Developer API"},
        ]
        if terminal_auth[0]:
            methods.append({"id": "terminal-login", "name": "Log in from the terminal",
                            "description": "Log in with your Google account by pasting a code in a terminal; works over SSH",
                            "type": "terminal", "args": ["--login"]})
        send({"jsonrpc": "2.0", "id": request_id, "result": {
            "protocolVersion": 1,
            "agentCapabilities": {
                "loadSession": True, "promptCapabilities": {"image": True, "audio": False, "embeddedContext": True},
                "sessionCapabilities": {"resume": {}, "close": {}, "load": {}, "list": {}},
                "auth": {"logout": {}}, "_meta": {"antigravity": {"tier": True, "systemPrompt": {"append": True}}}},
            "agentInfo": {"name": "Antigravity ACP Server", "version": "1.5.18"}, "authMethods": methods}})
    elif method == "authenticate":
        chosen = params.get("methodId")
        if chosen == "gemini-api-key":
            if not os.environ.get("GEMINI_API_KEY"):
                send({"jsonrpc": "2.0", "id": request_id, "error": {"code": -32602, "message": "GEMINI_API_KEY is not set; pass an API key in _meta.apiKey or set the GEMINI_API_KEY environment variable."}})
                continue
            write("method", "gemini-api-key")
            send({"jsonrpc": "2.0", "id": request_id, "result": {}})
        else:
            send({"jsonrpc": "2.0", "id": request_id, "error": {"code": -32603, "message": "No browser is available here (no graphical display is available to open a browser). Choose \"Log in from the terminal\" instead, or use a Gemini API key."}})
    elif method in ("session/new", "session/resume"):
        if not signed_in():
            send({"jsonrpc": "2.0", "id": request_id, "error": {"code": -32000, "message": "Authentication required"}})
            continue
        note = params.get("_meta", {}).get("antigravity", {}).get("systemPrompt", {}).get("append")
        if method == "session/new":
            session_id = "agy-%d" % (len(os.listdir(os.path.join(home, "sessions"))) + 1)
            record = {"notes": []}
        else:
            session_id = params["sessionId"]
            record = stored(session_id)
            if record is None:
                send({"jsonrpc": "2.0", "id": request_id, "error": {"code": -32603, "message": "Failed to read session %s; retry, or load it with session/load" % session_id}})
                continue
        if note:
            record["notes"].append(note)
        store(session_id, record)
        live[session_id] = {"model": "fast", "effort": "low"}
        result = choices(live[session_id])
        if method == "session/new":
            result["sessionId"] = session_id
        send({"jsonrpc": "2.0", "id": request_id, "result": result})
    elif method == "session/set_config_option":
        session = live[params["sessionId"]]
        if params["configId"] == "model":
            if params["value"] not in LEVELS:
                send({"jsonrpc": "2.0", "id": request_id, "error": {"code": -32602, "message": "Unknown model ID: %s" % params["value"]}})
                continue
            session["model"] = params["value"]
            if session["effort"] not in LEVELS[session["model"]]:
                session["effort"] = "low"
        elif params["configId"] == "thought_level":
            if params["value"] not in LEVELS[session["model"]]:
                send({"jsonrpc": "2.0", "id": request_id, "error": {"code": -32602, "message": "Unknown thinking level: %s" % params["value"]}})
                continue
            session["effort"] = params["value"]
        send({"jsonrpc": "2.0", "id": request_id, "result": {"configOptions": options(session)}})
    elif method == "session/prompt":
        if not signed_in():
            send({"jsonrpc": "2.0", "id": request_id, "error": {"code": -32000, "message": "Authentication required"}})
            continue
        text = "".join(block.get("text", "") for block in params.get("prompt", []))
        prompt(request_id, params["sessionId"], text)
    elif method == "session/cancel":
        held = sleeping.pop(params.get("sessionId"), None)
        if held:
            call(params["sessionId"], "tool_call_update", "sleep-1", "run_command", held[1], "failed", "sleep 60", {
                "rawOutput": {"output": ""}, "content": [{"type": "content", "content": {"type": "text", "text": ""}}]})
            finish(held[0], "cancelled")
    elif request_id is not None:
        send({"jsonrpc": "2.0", "id": request_id, "error": {"code": -32601, "message": "Method not found"}})
