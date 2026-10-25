"""A stand-in for the Claude and OpenAI APIs for simulator tests.

Replays tests/fixtures/<provider>-<name>.sse for a streaming request, where
<name> comes from a last user message of the form "@<name>" (anything else
replays "text"). A non-streaming request (the title) gets
<provider>-title.json. A fixture with a "#status N" header line replies with
that status. Leading ":" comment lines are dropped.

"@prog-<name>" replies, in either provider's stream format, with a short text
and a lua fence holding tests/fixtures/programs/<name>.lua (or
prompt/<name>.lua when that is missing).

    api = FakeAPI().start()
    api.url          http://127.0.0.1:<port>
    api.delay        seconds between 120-byte chunks of a stream (0 = none)
    api.requests     [{provider, stream, path, body, headers}, ...]
"""
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

FIXTURES = Path(__file__).resolve().parents[1] / "fixtures"
PROMPT = Path(__file__).resolve().parents[2] / "prompt"
CHUNK = 120


def load_fixture(provider, name, ext):
    """(status, body bytes) of tests/fixtures/<provider>-<name>.<ext>, or None."""
    path = FIXTURES / f"{provider}-{name}.{ext}"
    if not path.exists():
        return None
    lines = path.read_bytes().split(b"\n")
    while lines and lines[0].startswith(b":"):
        lines.pop(0)
    status = 200
    if lines and lines[0].startswith(b"#status "):
        status = int(lines.pop(0).split()[1])
    return status, b"\n".join(lines)


def program_source(name):
    """The text of program fixture <name>.lua, or None."""
    for path in (FIXTURES / "programs" / f"{name}.lua", PROMPT / f"{name}.lua"):
        if path.exists():
            return path.read_text()
    return None


def _sse(events):
    return "".join(f"event: {name}\ndata: {json.dumps(data)}\n\n" for name, data in events).encode()


def _pieces(text, size=200):
    return [text[i:i + size] for i in range(0, len(text), size)] or [""]


def claude_stream(text):
    """A Claude Messages stream whose reply is `text`."""
    events = [
        ("message_start", {"type": "message_start", "message": {
            "id": "msg_prog", "type": "message", "role": "assistant", "model": "claude-opus-5-5",
            "content": [], "stop_reason": None, "usage": {"input_tokens": 10, "output_tokens": 1}}}),
        ("content_block_start", {"type": "content_block_start", "index": 0,
                                 "content_block": {"type": "text", "text": ""}}),
    ]
    for piece in _pieces(text):
        events.append(("content_block_delta", {"type": "content_block_delta", "index": 0,
                                               "delta": {"type": "text_delta", "text": piece}}))
    events += [
        ("content_block_stop", {"type": "content_block_stop", "index": 0}),
        ("message_delta", {"type": "message_delta", "delta": {"stop_reason": "end_turn"},
                           "usage": {"output_tokens": 50}}),
        ("message_stop", {"type": "message_stop"}),
    ]
    return _sse(events)


def openai_stream(text):
    """An OpenAI Responses stream whose reply is `text`."""
    item = {"id": "msg_prog", "type": "message", "role": "assistant"}
    events = [
        ("response.created", {"type": "response.created", "sequence_number": 0,
                              "response": {"id": "resp_prog", "status": "in_progress", "output": []}}),
        ("response.output_item.added", {"type": "response.output_item.added", "output_index": 0,
                                        "sequence_number": 1,
                                        "item": {**item, "status": "in_progress", "content": []}}),
    ]
    for piece in _pieces(text):
        events.append(("response.output_text.delta", {
            "type": "response.output_text.delta", "item_id": "msg_prog", "output_index": 0,
            "content_index": 0, "delta": piece, "sequence_number": len(events)}))
    done = {**item, "status": "completed", "content": [{"type": "output_text", "text": text, "annotations": []}]}
    events += [
        ("response.output_item.done", {"type": "response.output_item.done", "output_index": 0,
                                       "item": done, "sequence_number": len(events)}),
        ("response.completed", {"type": "response.completed", "sequence_number": len(events) + 1,
                                "response": {"id": "resp_prog", "status": "completed", "output": [done],
                                             "usage": {"input_tokens": 10, "output_tokens": 50}}}),
    ]
    return _sse(events)


def program_reply(provider, name):
    """(200, stream bytes) replying with program <name>, or None."""
    src = program_source(name)
    if src is None:
        return None
    if not src.endswith("\n"):
        src += "\n"
    text = f"Here is {name}.lua:\n\n```lua\n{src}```\n"
    return 200, (openai_stream(text) if provider == "openai" else claude_stream(text))


def _text(content):
    if isinstance(content, str):
        return content
    return "".join(b.get("text", "") for b in content if isinstance(b, dict))


def last_user_text(body):
    """The text of the last user message in a Messages or Responses body."""
    msgs = body.get("messages") or body.get("input") or []
    if isinstance(msgs, str):
        return msgs
    for m in reversed(msgs):
        if isinstance(m, dict) and m.get("role") == "user":
            return _text(m.get("content", ""))
    return ""


class FakeAPI:
    def __init__(self):
        self.requests = []
        self.delay = 0.0
        self._server = None

    def start(self):
        api = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def _send(self, status, ctype, body):
                self.send_response(status)
                self.send_header("Content-Type", ctype)
                self.send_header("Connection", "close")
                self.end_headers()
                try:
                    if ctype == "text/event-stream":
                        for i in range(0, len(body), CHUNK):
                            self.wfile.write(body[i:i + CHUNK])
                            self.wfile.flush()
                            if api.delay:
                                time.sleep(api.delay)
                    else:
                        self.wfile.write(body)
                except (ConnectionResetError, BrokenPipeError):
                    pass  # the app stopped or cancelled the request

            def do_POST(self):
                raw = self.rfile.read(int(self.headers.get("Content-Length", 0)))
                try:
                    body = json.loads(raw or b"{}")
                except ValueError:
                    body = {}
                provider = "openai" if "/responses" in self.path else "claude"
                stream = bool(body.get("stream"))
                api.requests.append(dict(provider=provider, stream=stream, path=self.path,
                                         body=body, headers=dict(self.headers)))
                if stream:
                    text = last_user_text(body)
                    name = text[1:].strip() if text.startswith("@") else "text"
                    if name.startswith("prog-"):
                        found = program_reply(provider, name[5:])
                    else:
                        found = load_fixture(provider, name, "sse") or load_fixture(provider, name, "json")
                else:
                    found = load_fixture(provider, "title", "json")
                if found is None:
                    return self._send(404, "text/plain", b"no fixture")
                status, data = found
                ctype = "text/event-stream" if stream and status == 200 else "application/json"
                self._send(status, ctype, data)

        self._server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self._server.serve_forever, daemon=True).start()
        return self

    @property
    def url(self):
        return f"http://127.0.0.1:{self._server.server_address[1]}"

    def stop(self):
        self._server.shutdown()
        self._server.server_close()
