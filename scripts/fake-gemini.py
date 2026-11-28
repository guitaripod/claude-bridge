"""A stand-in for the Gemini API that answers from a script, for running an agent with no account.

    scripts/fake-gemini.py <port> <log dir> [script.json]

Every request is written to <log dir>/NNN-<verb>.json, so what the agent asked for (its system
prompt, its tools, the conversation so far) can be read back. The script is a list of turns the
model takes, one per generateContent call that carries function declarations:
    {"text": "..."}                                  plain words
    {"thought": "...", "text": "..."}                a thought, then words
    {"calls": [{"name": "...", "args": {...}}]}      function calls
    {"status": 429, "error": "...", "grpc": "RESOURCE_EXHAUSTED"}  an API failure
    {"delay": seconds, ...}                          wait before answering
    {"stall": seconds, ...}                          send half the words, then wait
When the script runs out the answer is "Done."; a call with no function declarations (a title, a
web search) is answered "Short title" and takes no turn.

Antigravity CLI reaches it with GEMINI_API_KEY set to anything and
GOOGLE_GEMINI_BASE_URL=http://127.0.0.1:<port>, signed in over ACP with the `gemini-api-key` method.
"""
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

port = int(sys.argv[1])
logdir = sys.argv[2]
script_path = sys.argv[3] if len(sys.argv) > 3 else None
os.makedirs(logdir, exist_ok=True)
lock = threading.Lock()
state = {"count": 0, "turn": 0}


def script():
    if not script_path or not os.path.exists(script_path):
        return []
    try:
        return json.load(open(script_path))
    except Exception:
        return []


def next_turn():
    with lock:
        steps = script()
        index = state["turn"]
        state["turn"] += 1
    if index < len(steps):
        return steps[index]
    return {"text": "Done."}


def chunk(parts, finish=None, usage=None):
    candidate = {"content": {"role": "model", "parts": parts}, "index": 0}
    if finish:
        candidate["finishReason"] = finish
    body = {"candidates": [candidate], "modelVersion": "fake-gemini", "responseId": "fake"}
    if usage:
        body["usageMetadata"] = usage
    return body


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def record(self, body):
        with lock:
            state["count"] += 1
            number = state["count"]
        verb = self.path.split("?")[0].rstrip("/").split("/")[-1].replace(":", "_")
        path = os.path.join(logdir, f"{number:03d}-{verb}.json")
        with open(path, "w") as handle:
            json.dump(
                {"method": self.command, "path": self.path, "headers": dict(self.headers), "body": body},
                handle,
                indent=1,
            )
        return number

    def send_json(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.record(None)
        if "/models" in self.path:
            names = ["gemini-3-pro", "gemini-3-flash"]
            self.send_json(
                200,
                {
                    "models": [
                        {
                            "name": f"models/{name}",
                            "displayName": name,
                            "inputTokenLimit": 1048576,
                            "outputTokenLimit": 65536,
                            "supportedGenerationMethods": ["generateContent", "countTokens"],
                        }
                        for name in names
                    ]
                },
            )
            return
        self.send_json(404, {"error": {"code": 404, "message": "not found", "status": "NOT_FOUND"}})

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        try:
            body = json.loads(raw) if raw else None
        except Exception:
            body = {"raw": raw.decode(errors="replace")}
        self.record(body)
        lowered = self.path.lower()
        if "counttokens" in lowered:
            self.send_json(200, {"totalTokens": 42})
            return
        if "generatecontent" not in lowered:
            self.send_json(404, {"error": {"code": 404, "message": "not found", "status": "NOT_FOUND"}})
            return
        has_tools = bool(body and any(tool.get("functionDeclarations") for tool in body.get("tools") or []))
        turn = next_turn() if has_tools else {"text": "Short title"}
        if turn.get("delay"):
            time.sleep(turn["delay"])
        if turn.get("status"):
            self.send_json(
                turn["status"],
                {
                    "error": {
                        "code": turn["status"],
                        "message": turn.get("error", "failed"),
                        "status": turn.get("grpc", "RESOURCE_EXHAUSTED"),
                    }
                },
            )
            return
        usage = {"promptTokenCount": 1200, "candidatesTokenCount": 30, "totalTokenCount": 1230}
        chunks = []
        if turn.get("thought"):
            chunks.append(chunk([{"text": turn["thought"], "thought": True}]))
        text = turn.get("text")
        if text:
            half = max(1, len(text) // 2)
            chunks.append(chunk([{"text": text[:half]}]))
            if turn.get("stall"):
                chunks.append({"stall": turn["stall"]})
            chunks.append(chunk([{"text": text[half:]}]))
        calls = turn.get("calls") or []
        if calls:
            chunks.append(
                chunk([{"functionCall": {"name": call["name"], "args": call.get("args", {})}} for call in calls])
            )
        chunks.append(chunk([{"text": ""}], finish=turn.get("finish", "STOP"), usage=usage))
        streaming = "streamgeneratecontent" in lowered
        if not streaming:
            parts = []
            for item in chunks:
                if "stall" in item:
                    continue
                parts += [p for p in item["candidates"][0]["content"]["parts"] if p.get("text") != "" or len(p) > 1]
            self.send_json(200, chunk(parts or [{"text": ""}], finish=turn.get("finish", "STOP"), usage=usage))
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()

        def write(data):
            self.wfile.write(f"{len(data):x}\r\n".encode() + data + b"\r\n")
            self.wfile.flush()

        try:
            for item in chunks:
                if "stall" in item:
                    time.sleep(item["stall"])
                    continue
                write(b"data: " + json.dumps(item).encode() + b"\n\n")
                time.sleep(0.05)
            write(b"")
        except Exception:
            pass


ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
