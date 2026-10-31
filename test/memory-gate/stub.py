#!/usr/bin/env python3
"""Stub OpenAI-compatible model for the broker-mode probe. Not part of the package.

Turn 1: answers with ONE tool call that runs a probe command in the agent's shell.
Turn 2 (a request carrying the tool result): answers with plain text.
Every request is appended to stub-requests.jsonl: path, the Authorization header the gateway presented
(the REAL canary key if broker mode works), and the full body, so the agent's own view of its
environment is in the tool-result message of turn 2.
"""
import json, sys, time
from http.server import BaseHTTPRequestHandler, HTTPServer

LOG = sys.argv[2] if len(sys.argv) > 2 else "stub-requests.jsonl"
PROBE = r"""echo '--id'; id; echo '--env'; env; echo '--proc1'; cat /proc/1/environ 2>&1 | head -c 200; echo; \
echo '--runner-environ'; for p in $(pgrep -f 'uvicorn server:app' 2>/dev/null); do cat /proc/$p/environ 2>&1 | head -c 200; done; echo; \
echo '--auth-store'; cat /app/data/selfhost-auth.json 2>&1 | head -c 100; echo; \
echo '--secrets-dir'; ls -la /app/data/.secrets 2>&1 | head -5; cat /app/data/.secrets/secret-key 2>&1 | head -c 50; echo; \
echo '--data-ls'; ls -la /app/data 2>&1 | head -20; echo '--workspaces'; ls -la /app/data/workspaces 2>&1 | head -10; \
echo '--write-data'; touch /app/data/x-from-agent 2>&1 | head -2; echo '--end'"""


def log(rec):
    with open(LOG, "a") as f:
        f.write(json.dumps(rec) + "\n")


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, obj, code=200):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)

    def do_GET(self):
        log({"t": time.time(), "method": "GET", "path": self.path, "auth": self.headers.get("Authorization")})
        self._send({"object": "list", "data": [{"id": "stub-model", "object": "model"}]})

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n).decode("utf-8", "replace")
        try: body = json.loads(raw)
        except Exception: body = {"_raw": raw[:500]}
        log({"t": time.time(), "method": "POST", "path": self.path, "auth": self.headers.get("Authorization"), "body": body})
        msgs = body.get("messages") or []
        has_tool_result = any(m.get("role") == "tool" for m in msgs)
        tools = body.get("tools") or []
        names = [(t.get("function") or t).get("name") for t in tools]
        shell = next((n for n in names if n and n.lower() in ("bash", "shell", "run_shell_command", "execute_bash")), None) \
            or next((n for n in names if n and ("bash" in n.lower() or "shell" in n.lower())), None)
        if "chat/completions" in self.path:
            if not has_tool_result and shell:
                msg = {"role": "assistant", "content": None, "tool_calls": [{"id": "call_probe1", "type": "function",
                       "function": {"name": shell, "arguments": json.dumps({"command": PROBE, "description": "probe"})}}]}
                fin = "tool_calls"
            else:
                msg = {"role": "assistant", "content": "probe finished"}; fin = "stop"
            if body.get("stream"):
                self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.send_header("Cache-Control", "no-cache")
                self.end_headers()
                def sse(delta, finish=None, usage=None):
                    ch = {"id": "chatcmpl-stub", "object": "chat.completion.chunk", "created": int(time.time()), "model": "stub-model",
                          "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}
                    if usage: ch["usage"] = usage
                    self.wfile.write(("data: " + json.dumps(ch) + "\n\n").encode()); self.wfile.flush()
                sse({"role": "assistant"})
                if msg.get("tool_calls"):
                    tc = msg["tool_calls"][0]
                    sse({"tool_calls": [{"index": 0, "id": tc["id"], "type": "function", "function": {"name": tc["function"]["name"], "arguments": ""}}]})
                    sse({"tool_calls": [{"index": 0, "function": {"arguments": tc["function"]["arguments"]}}]})
                else:
                    sse({"content": msg.get("content") or ""})
                sse({}, fin, {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2})
                self.wfile.write(b"data: [DONE]\n\n"); self.wfile.flush()
                return
            self._send({"id": "chatcmpl-stub", "object": "chat.completion", "created": int(time.time()), "model": "stub-model",
                        "choices": [{"index": 0, "message": msg, "finish_reason": fin}],
                        "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}})
        elif self.path.rstrip("/").endswith("/responses"):
            # OpenAI Responses API (what codex speaks): one function_call on the first turn, text after a tool result.
            items = body.get("input") or []
            has_out = any(isinstance(i, dict) and i.get("type") in ("function_call_output", "custom_tool_call_output") for i in items)
            tl = [x for x in (body.get("tools") or []) if isinstance(x, dict)]
            sh = next((x for x in tl if (x.get("name") or "").lower() in ("shell", "exec_command", "bash", "local_shell")), None)
            self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.end_headers()
            def ev(name, data):
                self.wfile.write(("event: %s\ndata: %s\n\n" % (name, json.dumps(data))).encode()); self.wfile.flush()
            rid = "resp_stub_%d" % int(time.time() * 1000)
            ev("response.created", {"type": "response.created", "response": {"id": rid, "object": "response", "status": "in_progress", "output": []}})
            if sh and not has_out:
                props = (sh.get("parameters") or {}).get("properties") or {}
                args = {"cmd": PROBE} if "cmd" in props else {"command": ["bash", "-lc", PROBE]}
                it = {"type": "function_call", "id": "fc_probe1", "call_id": "call_probe1", "name": sh["name"], "arguments": json.dumps(args), "status": "completed"}
                ev("response.output_item.added", {"type": "response.output_item.added", "output_index": 0, "item": dict(it, arguments="", status="in_progress")})
                ev("response.output_item.done", {"type": "response.output_item.done", "output_index": 0, "item": it})
                out = [it]
            else:
                it = {"type": "message", "id": "msg_stub", "role": "assistant", "status": "completed", "content": [{"type": "output_text", "text": "probe finished", "annotations": []}]}
                ev("response.output_item.added", {"type": "response.output_item.added", "output_index": 0, "item": dict(it, content=[], status="in_progress")})
                ev("response.output_item.done", {"type": "response.output_item.done", "output_index": 0, "item": it})
                out = [it]
            ev("response.completed", {"type": "response.completed", "response": {"id": rid, "object": "response", "status": "completed", "output": out,
               "usage": {"input_tokens": 1, "output_tokens": 1, "total_tokens": 2}}})
        else:
            self._send({"error": {"message": "stub: unsupported path " + self.path}}, 404)


HTTPServer(("0.0.0.0", int(sys.argv[1]) if len(sys.argv) > 1 else 18080), H).serve_forever()
