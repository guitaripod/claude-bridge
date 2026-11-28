"""Drive an ACP agent by hand and print every line it says.

    scripts/acp-probe.py steps.json -- <agent command...>

steps.json is a list of steps, each one of:
    {"method": "initialize", "params": {...}, "wait": 60}      a request, waited on for its answer
    {"method": "session/cancel", "params": {...}, "notify": true}  a notification
    {"method": "session/prompt", "params": {...}, "nowait": true}  a request left pending
    {"sleep": 3}                                                   read for a while
"$SESSION" in a step's params is the id of the last session the agent opened.

A permission question is answered with its first allow option (PROBE_DENY=1 refuses instead), and
any other request from the agent is answered "method not found", the way claude-bridge answers.
PROBE_CLIP sets how much of each line is printed, PROBE_TAIL how long to listen after the last step.

To see how Antigravity behaves with no Google account, pair it with scripts/fake-gemini.py:
give the agent a scratch HOME, GEMINI_API_KEY=anything and
GOOGLE_GEMINI_BASE_URL=http://127.0.0.1:<port>, and send `authenticate` with
{"methodId": "gemini-api-key"} before `session/new`.
"""
import json
import os
import select
import subprocess
import sys
import time


def main():
    split = sys.argv.index("--")
    steps = json.load(open(sys.argv[1]))
    command = sys.argv[split + 1 :]
    limit = int(os.environ.get("PROBE_CLIP", "1800"))
    proc = subprocess.Popen(
        command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0
    )
    buffers = {proc.stdout.fileno(): b"", proc.stderr.fileno(): b""}
    names = {proc.stdout.fileno(): "OUT", proc.stderr.fileno(): "ERR"}
    session = {"id": None}
    started = time.time()

    def stamp():
        return f"[{time.time() - started:6.2f}]"

    def send(obj):
        text = json.dumps(obj)
        print(stamp(), ">>>", text[:limit], flush=True)
        proc.stdin.write(text.encode() + b"\n")
        proc.stdin.flush()

    def handle(line, name):
        if name == "ERR":
            print(stamp(), "ERR", line[:limit], flush=True)
            return None
        try:
            obj = json.loads(line)
        except Exception:
            print(stamp(), "OUT?", line[:limit], flush=True)
            return None
        print(stamp(), "<<<", json.dumps(obj)[:limit], flush=True)
        if "method" in obj and "id" in obj:
            if obj["method"] == "session/request_permission":
                options = obj["params"].get("options", [])
                allow = next((o for o in options if o.get("kind", "").startswith("allow")), None)
                if os.environ.get("PROBE_DENY") or allow is None:
                    send({"jsonrpc": "2.0", "id": obj["id"], "result": {"outcome": {"outcome": "cancelled"}}})
                else:
                    send({"jsonrpc": "2.0", "id": obj["id"], "result": {"outcome": {"outcome": "selected", "optionId": allow["optionId"]}}})
            else:
                send({"jsonrpc": "2.0", "id": obj["id"], "error": {"code": -32601, "message": "Method not found: " + obj["method"]}})
        result = obj.get("result")
        if isinstance(result, dict) and result.get("sessionId"):
            session["id"] = result["sessionId"]
        return obj

    def pump(seconds, until_id=None):
        deadline = time.time() + seconds
        while time.time() < deadline:
            ready, _, _ = select.select(list(buffers), [], [], 0.2)
            for fd in ready:
                chunk = os.read(fd, 65536)
                if not chunk:
                    if proc.poll() is not None:
                        print(stamp(), "EXIT", proc.returncode, flush=True)
                        return "exit"
                    continue
                buffers[fd] += chunk
                while b"\n" in buffers[fd]:
                    raw, buffers[fd] = buffers[fd].split(b"\n", 1)
                    obj = handle(raw.decode(errors="replace"), names[fd])
                    if until_id is not None and obj and obj.get("id") == until_id and "method" not in obj:
                        return "answered"
            if proc.poll() is not None and not ready:
                print(stamp(), "EXIT", proc.returncode, flush=True)
                return "exit"
        return "timeout"

    next_id = 0
    for step in steps:
        if "sleep" in step:
            pump(step["sleep"])
            continue
        params = json.loads(json.dumps(step.get("params", {})).replace("$SESSION", session["id"] or ""))
        if step.get("notify"):
            send({"jsonrpc": "2.0", "method": step["method"], "params": params})
            continue
        next_id += 1
        send({"jsonrpc": "2.0", "id": next_id, "method": step["method"], "params": params})
        if step.get("nowait"):
            continue
        outcome = pump(step.get("wait", 30), until_id=next_id)
        if outcome != "answered":
            print(stamp(), "---", step["method"], outcome, flush=True)
            if outcome == "exit":
                return
    pump(float(os.environ.get("PROBE_TAIL", "1")))
    proc.stdin.close()
    try:
        proc.wait(timeout=5)
    except Exception:
        proc.kill()
    print(stamp(), "CLOSED", proc.returncode, flush=True)


main()
